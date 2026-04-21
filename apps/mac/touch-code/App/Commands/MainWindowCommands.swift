import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// T3 main-window shortcuts. Attached to the single `WindowGroup` in
/// `TouchCodeApp`. Binds three chords requested by the main-window redesign spec:
///
/// - `⌘E` → open the active Worktree in the resolved default editor (per-Project
///   override → global default → Finder). Forwards to
///   `EditorFeature.Action.openDefaultInCurrentWorktreeRequested` so TestStore
///   observes the full chain.
/// - `⌘⇧G` → toggle the Git Viewer overlay for the active Worktree. Dispatches
///   `RootFeature.Action.gitViewerToggledForCurrentWorktree`; T2's Header button
///   sends the same action so the two entry points share semantics.
/// - `⌘K` → open the Sidebar's Space switcher popover. Bumps
///   `RootFeature.State.spaceSwitcherOpenToken` via
///   `.openSpaceSwitcherRequested`; T1's sidebar view observes the token via
///   `.onChange(of:)` and opens the popover. If T1 later exposes a direct
///   open-only action the token wiring collapses to a direct dispatch.
///
/// Collision notes: `Cmd-E` (Use Selection for Find) and `Cmd-Shift-G` (Find
/// Previous) are AppKit defaults in editable-text contexts. This app has no
/// editable text fields at the window scope, so the menu binding wins in the
/// common case. In-GitViewer keybindings (`j / k / g / G / …`) gate on
/// `press.modifiers.isEmpty` and are never shadowed by these ⌘-modified chords.
struct MainWindowCommands: Commands {
  let store: StoreOf<RootFeature>
  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open in Default Editor") {
        sendOpenDefault()
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(!hasActiveWorktree)

      Button("Toggle Git Viewer") {
        store.send(.gitViewerToggledForCurrentWorktree)
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      .disabled(!hasActiveWorktree)

      Button("Switch Space…") {
        store.send(.openSpaceSwitcherRequested)
      }
      .keyboardShortcut("k", modifiers: .command)
    }
  }

  private var hasActiveWorktree: Bool { store.state.selection.worktreeID != nil }

  @MainActor
  private func sendOpenDefault() {
    guard
      let spaceID = store.state.selection.spaceID,
      let projectID = store.state.selection.projectID,
      let worktreeID = store.state.selection.worktreeID
    else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let path = catalog
        .spaces.first(where: { $0.id == spaceID })?
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?.path
    else { return }
    store.send(.editor(.openDefaultInCurrentWorktreeRequested(
      spaceID: spaceID,
      projectID: projectID,
      worktreeID: worktreeID,
      worktreePath: path
    )))
  }
}
