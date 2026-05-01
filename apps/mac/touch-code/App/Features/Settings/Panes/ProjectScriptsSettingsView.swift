import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Scripts sub-pane (M5). Rendered as a grouped `Form` so the
/// pane shares the macOS System-Settings look used by every other
/// project pane (General / Hooks).
///
/// Lifecycle scripts (git_repo only) each own a dedicated Section with
/// an icon-led header and a footer example — this lets users tell
/// Setup / Archive / Delete apart at a glance and keeps the layout
/// consistent with `RepositoryScriptsSettingsView` in supacode. The
/// user-defined `[ScriptDefinition]` list lives in a single Section so
/// `.onMove` keeps working; the trailing `+` is a kind-aware menu that
/// only offers predefined kinds the project doesn't already use.
///
/// Reads come from `@Environment(SettingsStore.self)` for live updates;
/// writes always go through the TCA reducer so test stores can spy on
/// individual writes without instantiating the SwiftUI view.
struct ProjectScriptsSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore

  /// IDs for the two top-level Sections; pure visibility logic lives on
  /// `visibleSections(for:)` so kind-conditional rendering is testable
  /// without the SwiftUI view tree (mirrors `ProjectGeneralSettingsView`).
  enum SectionID: String, CaseIterable, Hashable {
    case lifecycle
    case scripts
  }

  /// Lifecycle is git_repo-only; Scripts is always visible.
  nonisolated static func visibleSections(for kind: ProjectKind) -> Set<SectionID> {
    switch kind {
    case .plainDir:
      return [.scripts]
    case .gitRepo:
      return Set(SectionID.allCases)
    }
  }

  /// Local set of script-IDs currently in expanded edit mode. Lives in
  /// view state because expansion is a transient UI affordance, not
  /// persisted settings.
  @State private var expandedScriptIDs: Set<UUID> = []

  // MARK: - Derived state

  private var entry: ProjectSettings? {
    settingsStore.settings.projects[projectID]
  }

  private var scripts: [ScriptDefinition] {
    entry?.scripts ?? []
  }

  private var git: GitProjectSettings {
    entry?.git ?? GitProjectSettings()
  }

  private var visible: Set<SectionID> {
    Self.visibleSections(for: store.state.kind)
  }

  /// Worktree the Run button targets. Prefers `state.lastFocusedWorktreeID`
  /// when set; falls back to the first worktree of this Project. nil
  /// disables every Run button.
  private var resolvedWorktreeID: WorktreeID? {
    if let id = store.state.lastFocusedWorktreeID,
      project?.worktrees.contains(where: { $0.id == id }) == true
    {
      return id
    }
    return project?.worktrees.first?.id
  }

  private var project: Project? {
    hierarchyManager.catalog.projects.first(where: { $0.id == projectID })
  }

  // MARK: - Body

  var body: some View {
    Form {
      if visible.contains(.lifecycle) {
        lifecycleSection(
          title: "Setup Script",
          subtitle: "Runs after a new worktree is created.",
          icon: "truck.box.badge.clock",
          iconColor: .blue,
          example: "pnpm install",
          text: git.createScript?.command ?? "",
          phase: .setup
        )
        lifecycleSection(
          title: "Archive Script",
          subtitle: "Runs before a worktree is archived.",
          icon: "archivebox",
          iconColor: .orange,
          example: "docker compose down",
          text: git.archiveScript?.command ?? "",
          phase: .archive
        )
        lifecycleSection(
          title: "Delete Script",
          subtitle: "Runs before a worktree is removed (files still on disk).",
          icon: "trash",
          iconColor: .red,
          example: "docker compose down",
          text: git.deleteScript?.command ?? "",
          phase: .delete
        )
      }

      if visible.contains(.scripts) {
        scriptsSection
      }

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Lifecycle Section

  @ViewBuilder
  private func lifecycleSection(
    title: String,
    subtitle: String,
    icon: String,
    iconColor: Color,
    example: String,
    text: String,
    phase: SettingsWriter.WorktreeLifecycle
  ) -> some View {
    Section {
      LifecycleEditor(
        initial: text,
        onCommit: { newValue in
          store.send(.setLifecycleScript(phase, newValue))
        }
      )
    } header: {
      Label {
        VStack(alignment: .leading, spacing: 0) {
          Text(title)
            .font(.body)
            .bold()
            .lineLimit(1)
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } icon: {
        Image(systemName: icon)
          .foregroundStyle(iconColor)
          .accessibilityHidden(true)
      }
      .labelStyle(.scriptSectionHeader)
    } footer: {
      Text("e.g., `\(example)`")
    }
  }

  // MARK: - Scripts Section

  @ViewBuilder
  private var scriptsSection: some View {
    Section {
      if scripts.isEmpty {
        Text("No scripts yet — use the + menu to add one.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(scripts) { script in
          ScriptDefinitionRow(
            script: script,
            isExpanded: Binding(
              get: { expandedScriptIDs.contains(script.id) },
              set: { expanded in
                if expanded {
                  expandedScriptIDs.insert(script.id)
                } else {
                  expandedScriptIDs.remove(script.id)
                }
              }
            ),
            onSave: { updated in
              saveEdit(updated)
            },
            onRun: {
              if let wtID = resolvedWorktreeID {
                store.send(.runScriptTapped(scriptID: script.id, worktreeID: wtID))
              }
            },
            onDelete: { deleteScript(id: script.id) },
            canRun: resolvedWorktreeID != nil
          )
        }
        .onMove { source, destination in
          var reordered = scripts
          reordered.move(fromOffsets: source, toOffset: destination)
          store.send(.setProjectScripts(reordered))
        }
      }
    } header: {
      HStack(spacing: 8) {
        Label {
          Text("Scripts")
            .font(.body)
            .bold()
        } icon: {
          Image(systemName: "terminal.fill")
            .foregroundStyle(.gray)
            .accessibilityHidden(true)
        }
        .labelStyle(.scriptSectionHeader)

        Spacer()

        addScriptMenu
      }
    } footer: {
      Text("Run from the toolbar, command palette, or keyboard shortcut.")
    }
  }

  @ViewBuilder
  private var addScriptMenu: some View {
    let usedKinds = Set(scripts.map(\.kind))
    Menu {
      ForEach(ScriptKind.allCases, id: \.self) { kind in
        if kind == .custom || !usedKinds.contains(kind) {
          Button {
            addScript(kind: kind)
          } label: {
            Label(kind.defaultName, systemImage: kind.defaultSystemImage)
          }
        }
      }
    } label: {
      Image(systemName: "plus")
        .accessibilityLabel("Add Script")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Add a new script")
  }

  // MARK: - Mutations

  private func addScript(kind: ScriptKind = .custom) {
    let newScript = ScriptDefinition(kind: kind)
    var updated = scripts
    updated.insert(newScript, at: 0)
    expandedScriptIDs.insert(newScript.id)
    store.send(.setProjectScripts(updated))
  }

  private func saveEdit(_ script: ScriptDefinition) {
    var updated = scripts
    if let index = updated.firstIndex(where: { $0.id == script.id }) {
      updated[index] = script
    } else {
      updated.insert(script, at: 0)
    }
    expandedScriptIDs.remove(script.id)
    store.send(.setProjectScripts(updated))
  }

  private func deleteScript(id: UUID) {
    let updated = scripts.filter { $0.id != id }
    expandedScriptIDs.remove(id)
    store.send(.setProjectScripts(updated))
  }
}

// MARK: - Section header label style

/// Horizontal icon + title pairing used by every Section header in this
/// pane. Mirrors supacode's `VerticallyCenteredLabelStyle` so the visual
/// rhythm matches across the two apps.
private struct ScriptSectionHeaderLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
      configuration.title
    }
  }
}

extension LabelStyle where Self == ScriptSectionHeaderLabelStyle {
  fileprivate static var scriptSectionHeader: ScriptSectionHeaderLabelStyle { .init() }
}

// MARK: - Lifecycle TextEditor

/// Tiny TextEditor wrapper that commits the user's edit to the writer
/// on each change. Per-keystroke calls are safe: the writer routes
/// through `SettingsStore.scheduleSave`, which cancels and re-arms a
/// debounced disk write so a burst of keystrokes only triggers a
/// single `AtomicFileStore.write` once typing settles.
///
/// The previous commit-on-blur design lost the user's edit if the
/// settings window closed (or the pane swapped to another Project)
/// while focus was still on the field — `@FocusState` is not
/// guaranteed to fire `false` before the view tears down.
private struct LifecycleEditor: View {
  let initial: String
  let onCommit: (String) -> Void

  var body: some View {
    TextEditor(
      text: Binding(
        get: { initial },
        set: { newValue in
          if newValue != initial {
            onCommit(newValue)
          }
        }
      )
    )
    .monospaced()
    .textEditorStyle(.plain)
    .autocorrectionDisabled()
    .frame(height: 90)
  }
}
