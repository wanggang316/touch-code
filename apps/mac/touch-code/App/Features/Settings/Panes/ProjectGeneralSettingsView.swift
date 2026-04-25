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
  nonisolated static func visibleSections(for kind: ProjectKind) -> Set<SectionID> {
    switch kind {
    case .plainDir:
      return [.editor, .defaultShell, .environment]
    case .gitRepo:
      return Set(SectionID.allCases)
    }
  }

  /// Captures the per-control write fan-out as plain `@Sendable` closures so
  /// the binding bodies stay short and tests can hit each route without
  /// instantiating the SwiftUI view. Each method below mirrors the body of
  /// the corresponding `Binding(set:)` in the rendered view; the bindings
  /// delegate here so the routing logic has a single home.
  struct WriteRoutes: Sendable {
    let projectID: ProjectID
    let writer: SettingsWriter

    func writeDefaultEditor(_ value: EditorID?) {
      let setter = writer.setProjectDefaultEditor
      Task { await setter(projectID, value) }
    }

    func writeDefaultShell(_ value: String?) {
      let setter = writer.setProjectDefaultShell
      Task { await setter(projectID, value) }
    }

    func writeWorktreeBaseRef(_ rawValue: String) {
      let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let payload: String? = trimmed.isEmpty ? nil : trimmed
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .worktreeBaseRef(payload)) }
    }

    func writeCopyIgnored(_ value: Bool?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .copyIgnoredOnWorktreeCreate(value)) }
    }

    func writeCopyUntracked(_ value: Bool?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .copyUntrackedOnWorktreeCreate(value)) }
    }

    func writeMergeStrategy(_ value: MergeStrategy?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .defaultMergeStrategy(value)) }
    }

    func writePostMergeAction(_ value: MergedWorktreeAction?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .postMergeAction(value)) }
    }

    func writeGithubDisabled(_ value: Bool) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .githubDisabled(value)) }
    }

    func writeEnvVar(key: String, value: String?) {
      let setter = writer.setProjectEnvVar
      Task { await setter(projectID, key, value) }
    }
  }

  private var routes: WriteRoutes {
    WriteRoutes(projectID: projectID, writer: settingsWriter)
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
      set: { routes.writeDefaultEditor($0) }
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
      set: { routes.writeDefaultShell($0) }
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
      set: { routes.writeWorktreeBaseRef($0) }
    )
  }

  private var copyIgnoredBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.copyIgnoredOnWorktreeCreate },
      set: { routes.writeCopyIgnored($0) }
    )
  }

  private var copyUntrackedBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.copyUntrackedOnWorktreeCreate },
      set: { routes.writeCopyUntracked($0) }
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
      set: { routes.writeMergeStrategy($0) }
    )
  }

  private var postMergeActionBinding: Binding<MergedWorktreeAction?> {
    Binding(
      get: { entry?.git?.postMergeAction },
      set: { routes.writePostMergeAction($0) }
    )
  }

  private var githubDisabledBinding: Binding<Bool> {
    Binding(
      get: { entry?.git?.githubDisabled ?? false },
      set: { routes.writeGithubDisabled($0) }
    )
  }

  // MARK: - Environment

  @ViewBuilder
  private var environmentSection: some View {
    Section("Environment") {
      EnvironmentEditorView(
        envVars: envVarsBinding,
        onChange: { key, newValue in
          routes.writeEnvVar(key: key, value: newValue)
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
