import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project General detail pane — Phase 2 5-Section Form.
///
/// Five sibling Sections in fixed order: Editor, Default Shell, Worktree,
/// GitHub, Environment. Worktree and GitHub render only when
/// `ProjectKind == .gitRepo`; the design doc's "kind drives sections, not
/// labels" rule means we never paint a "this is a git repo" affordance —
/// the sections simply appear or don't.
///
/// All writes route through `SettingsWriter` closures injected on the
/// dependency, so tests can intercept individual fields without
/// instantiating a `SettingsStore`. Reads come from
/// `@Environment(SettingsStore.self)` for live updates and from the local
/// `ProjectSettingsFeature.State` for kind / lastWriteFailure.
struct ProjectGeneralSettingsView: View {
  let projectID: ProjectID
  let store: StoreOf<ProjectSettingsFeature>
  let descriptors: [EditorDescriptor]

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore
  @Dependency(SettingsWriter.self) private var settingsWriter

  /// IDs for the five Sections — useful for the kind-render tests so they
  /// can assert visibility without inspecting SwiftUI's view tree.
  enum SectionID: String, CaseIterable, Hashable {
    case editor
    case defaultShell
    case worktree
    case github
    case environment
  }

  /// Pure visibility logic. Worktree / GitHub gate on `kind == .gitRepo`;
  /// everything else is always visible.
  static func visibleSections(for kind: ProjectKind) -> Set<SectionID> {
    switch kind {
    case .plainDir:
      return [.editor, .defaultShell, .environment]
    case .gitRepo:
      return Set(SectionID.allCases)
    }
  }

  private var visible: Set<SectionID> {
    Self.visibleSections(for: store.state.kind)
  }

  private var entry: ProjectSettings? {
    settingsStore.settings.projects[projectID]
  }

  private var general: GeneralSettings {
    settingsStore.settings.general
  }

  var body: some View {
    Form {
      if visible.contains(.editor) {
        editorSection
      }
      if visible.contains(.defaultShell) {
        defaultShellSection
      }
      if visible.contains(.worktree) {
        worktreeSection
      }
      if visible.contains(.github) {
        githubSection
      }
      if visible.contains(.environment) {
        environmentSection
      }

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundColor(.red)
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Editor

  @ViewBuilder
  private var editorSection: some View {
    Section("Editor") {
      OptionalOverridePicker<EditorID>(
        title: "Default editor",
        selection: editorBinding,
        inheritedValue: general.defaultEditorID,
        options: editorOptions,
        inheritedLabel: { id in
          guard let id else { return "Auto" }
          return descriptors.first(where: { $0.id == id })?.displayName ?? id
        }
      )
    }
  }

  private var editorOptions: [OptionalOverridePicker<EditorID>.Option] {
    EditorPickerRow.sorted(descriptors).map { descriptor in
      .init(value: descriptor.id, label: descriptor.displayName)
    }
  }

  private var editorBinding: Binding<EditorID?> {
    Binding(
      get: { entry?.defaultEditor },
      set: { newValue in
        let writer = settingsWriter.setProjectDefaultEditor
        Task { await writer(projectID, newValue) }
      }
    )
  }

  // MARK: - Default Shell

  @ViewBuilder
  private var defaultShellSection: some View {
    Section("Default Shell") {
      OptionalOverridePicker<String>(
        title: "Shell",
        selection: shellBinding,
        // GeneralSettings.defaultShell does not exist today — when a future
        // wave adds it, swap this literal for the real field. The live
        // resolved-shell logic across the app already falls back to
        // /bin/zsh, so the inherit row label matches the runtime default.
        inheritedValue: "/bin/zsh",
        options: shellOptions,
        inheritedLabel: { value in value ?? "/bin/zsh" }
      )
    }
  }

  private var shellOptions: [OptionalOverridePicker<String>.Option] {
    ShellRegistry.installed.map { path in
      .init(value: path, label: path)
    }
  }

  private var shellBinding: Binding<String?> {
    Binding(
      get: { entry?.defaultShell },
      set: { newValue in
        let writer = settingsWriter.setProjectDefaultShell
        Task { await writer(projectID, newValue) }
      }
    )
  }

  // MARK: - Worktree

  @ViewBuilder
  private var worktreeSection: some View {
    Section("Worktree") {
      LabeledContent("Base directory") {
        Text(entry?.worktreesDirectory ?? "—")
          .foregroundStyle(entry?.worktreesDirectory == nil ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Choose…") { chooseWorktreeDirectory() }
        if entry?.worktreesDirectory != nil {
          Button("Clear") {
            store.send(.setWorktreeBaseDirectory(nil))
          }
        }
        Spacer()
      }

      TextField("Base ref", text: worktreeBaseRefBinding, prompt: Text("origin/HEAD"))

      TriStateOverrideToggle(
        title: "Copy .gitignore'd files",
        selection: copyIgnoredBinding,
        inheritedValue: false
      )
      TriStateOverrideToggle(
        title: "Copy untracked files",
        selection: copyUntrackedBinding,
        inheritedValue: false
      )
    }
  }

  private var worktreeBaseRefBinding: Binding<String> {
    Binding(
      get: { entry?.git?.worktreeBaseRef ?? "" },
      set: { newValue in
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String? = trimmed.isEmpty ? nil : trimmed
        let writer = settingsWriter.setProjectGitField
        Task { await writer(projectID, .worktreeBaseRef(payload)) }
      }
    )
  }

  private var copyIgnoredBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.copyIgnoredOnWorktreeCreate },
      set: { newValue in
        let writer = settingsWriter.setProjectGitField
        Task { await writer(projectID, .copyIgnoredOnWorktreeCreate(newValue)) }
      }
    )
  }

  private var copyUntrackedBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.copyUntrackedOnWorktreeCreate },
      set: { newValue in
        let writer = settingsWriter.setProjectGitField
        Task { await writer(projectID, .copyUntrackedOnWorktreeCreate(newValue)) }
      }
    )
  }

  // MARK: - GitHub

  @ViewBuilder
  private var githubSection: some View {
    Section("GitHub") {
      OptionalOverridePicker<MergeStrategy>(
        title: "Merge strategy",
        selection: mergeStrategyBinding,
        inheritedValue: general.defaultMergeStrategy,
        options: MergeStrategy.allCases.map {
          .init(value: $0, label: $0.displayName)
        },
        inheritedLabel: { value in
          (value ?? .squash).displayName
        }
      )

      OptionalOverridePicker<MergedWorktreeAction>(
        title: "After merging a PR",
        selection: postMergeActionBinding,
        inheritedValue: general.postMergeAction,
        options: MergedWorktreeAction.allCases.map {
          .init(value: $0, label: $0.displayName)
        },
        inheritedLabel: { value in
          (value ?? .ask).displayName
        }
      )

      Toggle("Disable GitHub integration for this Project", isOn: githubDisabledBinding)
    }
  }

  private var mergeStrategyBinding: Binding<MergeStrategy?> {
    Binding(
      get: { entry?.git?.defaultMergeStrategy },
      set: { newValue in
        let writer = settingsWriter.setProjectGitField
        Task { await writer(projectID, .defaultMergeStrategy(newValue)) }
      }
    )
  }

  private var postMergeActionBinding: Binding<MergedWorktreeAction?> {
    Binding(
      get: { entry?.git?.postMergeAction },
      set: { newValue in
        let writer = settingsWriter.setProjectGitField
        Task { await writer(projectID, .postMergeAction(newValue)) }
      }
    )
  }

  private var githubDisabledBinding: Binding<Bool> {
    Binding(
      get: { entry?.git?.githubDisabled ?? false },
      set: { newValue in
        let writer = settingsWriter.setProjectGitField
        Task { await writer(projectID, .githubDisabled(newValue)) }
      }
    )
  }

  // MARK: - Environment

  @ViewBuilder
  private var environmentSection: some View {
    Section("Environment") {
      EnvironmentEditorView(
        envVars: envVarsBinding,
        onChange: { key, newValue in
          let writer = settingsWriter.setProjectEnvVar
          Task { await writer(projectID, key, newValue) }
        },
        footer:
          "Values are stored in plain text in settings.json. Do not paste credentials "
          + "you wouldn't keep in a config file."
      )
    }
  }

  private var envVarsBinding: Binding<[String: String]> {
    Binding(
      get: { entry?.envVars ?? [:] },
      // Writes always fan out through `onChange` per row; the @Binding setter
      // is wired so SwiftUI's diff detects mutations from the parent without
      // a separate write path.
      set: { _ in }
    )
  }

  // MARK: - Helpers

  private func chooseWorktreeDirectory() {
    let pane = NSOpenPanel()
    pane.canChooseDirectories = true
    pane.canChooseFiles = false
    pane.allowsMultipleSelection = false
    pane.message = "Choose a directory for worktree storage"
    pane.begin { response in
      if response == .OK, let url = pane.urls.first {
        store.send(.setWorktreeBaseDirectory(url.path))
      }
    }
  }
}
