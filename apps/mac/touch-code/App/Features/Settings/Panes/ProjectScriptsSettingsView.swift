import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Scripts sub-pane (M5). Two Sections:
///
///   * **Worktree Lifecycle** — git_repo only. Three TextEditors bound
///     to `git.setupScript` / `archiveScript` / `deleteScript`. Writes
///     route through `SettingsWriter.setProjectLifecycleScript` on the
///     reducer.
///   * **Scripts** — user-defined `[ScriptDefinition]` list with inline
///     edit (`ScriptDefinitionRow`), `+ Add` to prepend a new row, and
///     `.onMove` for drag-to-reorder. Run dispatches
///     `HierarchyClient.runScript`; Delete prompts via the row's
///     confirmation dialog.
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
    List {
      if visible.contains(.lifecycle) {
        lifecycleSection
      }
      if visible.contains(.scripts) {
        scriptsSection
      }

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundColor(.red)
        }
      }
    }
    .listStyle(.inset)
  }

  // MARK: - Lifecycle Section

  @ViewBuilder
  private var lifecycleSection: some View {
    Section("Worktree Lifecycle") {
      lifecycleEditor(
        label: "Setup",
        text: git.setupScript,
        caption: "Run after a new worktree is created.",
        phase: .setup
      )
      lifecycleEditor(
        label: "Archive",
        text: git.archiveScript,
        caption: "Run before archiving a worktree.",
        phase: .archive
      )
      lifecycleEditor(
        label: "Delete",
        text: git.deleteScript,
        caption: "Run before removing a worktree (files still on disk).",
        phase: .delete
      )
    }
  }

  @ViewBuilder
  private func lifecycleEditor(
    label: String,
    text: String,
    caption: String,
    phase: SettingsWriter.WorktreeLifecycle
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.headline)
      // Local debounced buffer: edits live in @State while the user types
      // and commit on blur (focus loss) so we do not write-on-every-
      // keystroke. The pure logic is `LifecycleEditor`.
      LifecycleEditor(
        initial: text,
        onCommit: { newValue in
          store.send(.setLifecycleScript(phase, newValue))
        }
      )
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Scripts Section

  @ViewBuilder
  private var scriptsSection: some View {
    Section {
      if scripts.isEmpty {
        Text("No scripts yet — click + Add to create one.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
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
      HStack {
        Text("Scripts")
        Spacer()
        Button {
          addScript()
        } label: {
          Label("Add", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: - Mutations

  private func addScript() {
    let newScript = ScriptDefinition()
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

// MARK: - Lifecycle TextEditor with commit-on-blur

/// Tiny TextEditor wrapper that buffers user input locally and commits
/// to the writer only when the field loses focus. Avoids the "write on
/// every keystroke" storm that a direct `Binding` setter would cause
/// against `SettingsStore.mutateProject`.
private struct LifecycleEditor: View {
  let initial: String
  let onCommit: (String) -> Void

  @State private var draft: String
  @FocusState private var focused: Bool

  init(initial: String, onCommit: @escaping (String) -> Void) {
    self.initial = initial
    self.onCommit = onCommit
    self._draft = State(initialValue: initial)
  }

  var body: some View {
    TextEditor(text: $draft)
      .font(.system(.body, design: .monospaced))
      .frame(minHeight: 60)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
      )
      .focused($focused)
      .onChange(of: focused) { _, isFocused in
        if !isFocused, draft != initial {
          onCommit(draft)
        }
      }
      .onChange(of: initial) { _, newInitial in
        // Upstream change while we are not editing — adopt it so the
        // displayed value matches the latest persisted state.
        if !focused {
          draft = newInitial
        }
      }
  }
}
