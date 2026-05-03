import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Scripts sub-pane (M5). Two tab modes selected by a top
/// segmented picker (rendered centred and chrome-less so it reads as a
/// macOS System-Settings tab strip rather than a Form Section header):
///
/// - **Worktree** — git-only setup / archive / delete lifecycle scripts,
///   each in its own grouped Section with an inline editor (one body of
///   text per phase, edited in place).
/// - **Commands** — user-defined `[ScriptDefinition]` rendered as a
///   compact list of rows (icon + name + first command line + edit /
///   delete buttons). Add and edit both push a modal sheet whose body
///   is a System-Settings-style Form (one field per row).
///
/// Reads come from `@Environment(SettingsStore.self)` for live updates;
/// writes always go through the TCA reducer so test stores can spy on
/// individual writes without instantiating the SwiftUI view.
struct ProjectScriptsSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore

  /// IDs for the two top-level tabs; pure visibility logic lives on
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

  private enum Tab: String, CaseIterable, Hashable {
    case worktree
    case commands
  }

  // Default to Commands — that's the most-visited tab (user-defined
  // scripts), and the entry path from the worktree-header
  // "Manage Scripts…" deep-link expects to land there.
  @State private var selectedTab: Tab = .commands
  /// Sheet presentation for both Add and Edit. Non-nil = sheet visible
  /// against this draft. `.sheet(item:)` requires Identifiable, which
  /// `ScriptDefinition` already conforms to.
  @State private var editingScript: ScriptDefinition?

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
    let showLifecycle =
      visible.contains(.lifecycle)
      && (!visible.contains(.scripts) || selectedTab == .worktree)
    let showScripts =
      visible.contains(.scripts)
      && (!visible.contains(.lifecycle) || selectedTab == .commands)

    VStack(spacing: 0) {
      if visible.contains(.lifecycle) && visible.contains(.scripts) {
        // Centred chromeless segmented picker — no Form Section wrapper,
        // no row-style background, fixed compact width. Reads as a
        // System-Settings tab strip rather than a heading row.
        Picker("", selection: $selectedTab) {
          Text("Worktree").tag(Tab.worktree)
          Text("Commands").tag(Tab.commands)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .center)
      }

      Form {
        if showLifecycle {
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

        if showScripts {
          scriptsListSection
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
    .sheet(item: $editingScript) { editing in
      ScriptEditorSheet(
        script: editing,
        isNew: !scripts.contains(where: { $0.id == editing.id }),
        onSave: { updated in
          saveEdit(updated)
          editingScript = nil
        },
        onCancel: { editingScript = nil }
      )
    }
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

  // MARK: - Scripts List Section

  @ViewBuilder
  private var scriptsListSection: some View {
    // Single Section, no icon-led title. Empty-state replaces the rows
    // when the project has no scripts. The footer hosts the Add button
    // (text label, not a bare `+` glyph) plus a one-line hint.
    Section {
      if scripts.isEmpty {
        Text("No scripts yet — click Add to create one.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(scripts) { script in
          ScriptListRow(
            script: script,
            canRun: resolvedWorktreeID != nil,
            onRun: {
              if let wtID = resolvedWorktreeID {
                store.send(.runScriptTapped(scriptID: script.id, worktreeID: wtID))
              }
            },
            onEdit: { editingScript = script },
            onDelete: { deleteScript(id: script.id) }
          )
          // Drag-to-reorder. `ForEach.onMove` doesn't paint drag
          // handles inside a grouped Form on macOS, so we wire the
          // drag/drop ourselves: each row carries its UUID as the
          // pasteboard payload and accepts a String drop, computing
          // the new index by source/target lookup. `ScriptListRow`
          // exposes a leading grip glyph + uses .onTapGesture (not
          // Button) for edit, so the mouse-down belongs to the
          // drag gesture rather than being swallowed by a Button.
          .draggable(script.id.uuidString)
          .dropDestination(for: String.self) { items, _ in
            handleScriptDrop(items: items, targetID: script.id)
          }
        }
      }
    } footer: {
      HStack(spacing: 12) {
        addScriptMenu
        Spacer()
        if !scripts.isEmpty {
          Text("Run from the toolbar, command palette, or keyboard shortcut.")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// Text-labeled "Add" button. Opens a kind picker that excludes
  /// predefined kinds already in use (so the user can't have two `Run`
  /// scripts), but always exposes `.custom`. Click → set
  /// `editingScript` to a freshly-built draft and the sheet handles
  /// persistence on Save.
  @ViewBuilder
  private var addScriptMenu: some View {
    let usedKinds = Set(scripts.map(\.kind))
    Menu {
      ForEach(ScriptKind.allCases, id: \.self) { kind in
        if kind == .custom || !usedKinds.contains(kind) {
          Button {
            editingScript = ScriptDefinition(kind: kind)
          } label: {
            Label {
              Text(kind.defaultName)
            } icon: {
              Image(systemName: kind.defaultSystemImage)
                .foregroundStyle(ScriptTintColorPalette.color(for: kind.defaultTintColor))
            }
          }
        }
      }
    } label: {
      Label("Add", systemImage: "plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  // MARK: - Mutations

  private func saveEdit(_ script: ScriptDefinition) {
    var updated = scripts
    if let index = updated.firstIndex(where: { $0.id == script.id }) {
      updated[index] = script
    } else {
      // New scripts append to the end of the list — the user can
      // drag them upward if they want a different priority.
      updated.append(script)
    }
    store.send(.setProjectScripts(updated))
  }

  private func deleteScript(id: UUID) {
    let updated = scripts.filter { $0.id != id }
    store.send(.setProjectScripts(updated))
  }

  /// Reorder via drag-drop. Source script is removed and re-inserted at
  /// the target row's index (above-the-target). Returns true on a real
  /// reorder so the system can run the success animation.
  private func handleScriptDrop(items: [String], targetID: UUID) -> Bool {
    guard let firstID = items.first,
      let sourceUUID = UUID(uuidString: firstID),
      sourceUUID != targetID,
      let sourceIndex = scripts.firstIndex(where: { $0.id == sourceUUID }),
      let targetIndex = scripts.firstIndex(where: { $0.id == targetID })
    else { return false }
    var updated = scripts
    let moved = updated.remove(at: sourceIndex)
    let insertIndex = min(max(targetIndex, 0), updated.count)
    updated.insert(moved, at: insertIndex)
    store.send(.setProjectScripts(updated))
    return true
  }
}

// MARK: - Section header label style (used by the lifecycle scripts only)

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

// MARK: - Lifecycle inline editor

/// Tiny TextEditor wrapper that commits the user's edit to the writer
/// on each change. Per-keystroke calls are safe: the writer routes
/// through `SettingsStore.scheduleSave`, which cancels and re-arms a
/// debounced disk write so a burst of keystrokes only triggers a
/// single `AtomicFileStore.write` once typing settles.
private struct LifecycleEditor: View {
  let initial: String
  let onCommit: (String) -> Void

  var body: some View {
    PlainCommandEditor(
      text: Binding(
        get: { initial },
        set: { newValue in
          if newValue != initial {
            onCommit(newValue)
          }
        }
      )
    )
    .frame(height: 90)
  }
}

// MARK: - Compact list row

/// One user-defined script as a single Form row. Layout from leading to
/// trailing:
///   - 6×6 grip glyph (line.3.horizontal) signalling drag-to-reorder
///   - script icon
///   - display name + first command line
///   - Run / Delete action buttons
///
/// The icon + name area uses `.onTapGesture(perform: onEdit)` instead
/// of wrapping in a Button — a Button's mouse-down is captured by the
/// system click-recognizer, which steals the drag from the row's
/// `.draggable` modifier (configured at the call site). With
/// onTapGesture, mouse-down belongs to the drag gesture and a quick
/// click still routes to onEdit.
private struct ScriptListRow: View {
  let script: ScriptDefinition
  let canRun: Bool
  let onRun: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  @State private var showDeleteConfirm = false
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      // Leading grip — visible only on row hover so it doesn't add
      // permanent chrome; standard macOS drag-handle glyph at .secondary.
      Image(systemName: "line.3.horizontal")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 14, alignment: .center)
        .opacity(isHovering ? 1 : 0)
        .help("Drag to reorder")

      Image(systemName: script.resolvedSystemImage)
        .frame(width: 18, alignment: .center)
        .foregroundStyle(ScriptTintColorPalette.color(for: script.resolvedTintColor))

      VStack(alignment: .leading, spacing: 2) {
        Text(script.displayName)
          .font(.body)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(firstCommandLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      Button(action: onRun) {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      .disabled(!canRun)
      .help(canRun ? "Run \(script.displayName)" : "No worktree available")

      Button(role: .destructive) {
        showDeleteConfirm = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .help("Delete \(script.displayName)")
      .confirmationDialog(
        "Delete script \"\(script.displayName)\"?",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) { onDelete() }
        Button("Cancel", role: .cancel) {}
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .onTapGesture(perform: onEdit)
  }

  /// First non-empty line of the script's command, or a placeholder when
  /// the command is empty (typical for a freshly-created script).
  private var firstCommandLine: String {
    let firstLine = script.command
      .split(whereSeparator: \.isNewline)
      .first
      .map { String($0).trimmingCharacters(in: .whitespaces) }
    if let firstLine, !firstLine.isEmpty {
      return firstLine
    }
    return "(empty)"
  }
}
