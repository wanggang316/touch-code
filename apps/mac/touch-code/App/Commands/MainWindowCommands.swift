import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// T3 main-window shortcuts. Attached to the single `WindowGroup` in
/// `TouchCodeApp`. Binds three chords requested by the main-window redesign spec:
///
/// - `⌘E` → open the active Worktree in the resolved default editor (per-Project
///   override → global default → Finder). Dispatches
///   `RootFeature.Action.openDefaultForCurrentWorktreeRequested`; the reducer
///   resolves the Worktree path from the catalog snapshot and forwards to
///   `EditorFeature.Action.openDefaultInCurrentWorktreeRequested`. Snapshot
///   reads cannot live in this `Commands` struct: `@Dependency` here falls
///   through to `HierarchyClient.liveValue`, whose `snapshot` accessor is a
///   `fatalError` stub, so any direct call from Commands crashes.
/// - `⌘⇧G` → toggle the Git Viewer overlay for the active Worktree. Dispatches
///   `RootFeature.Action.gitViewerToggledForCurrentWorktree`; T2's Header button
///   sends the same action so the two entry points share semantics.
/// - `⌘K` → open the Sidebar's Space switcher popover. Dispatches
///   `RootFeature.Action.openSpaceSwitcherRequested`; the root reducer
///   forwards to `.sidebar(.externalSpacePopoverOpenRequested)` which sets
///   `isSpacePopoverPresented = true`.
///
/// Collision notes: `Cmd-E` (Use Selection for Find) and `Cmd-Shift-G` (Find
/// Previous) are AppKit defaults in editable-text contexts. This app has no
/// editable text fields at the window scope, so the menu binding wins in the
/// common case. In-GitViewer keybindings (`j / k / g / G / …`) gate on
/// `press.modifiers.isEmpty` and are never shadowed by these ⌘-modified chords.
struct MainWindowCommands: Commands {
  let store: StoreOf<RootFeature>

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open in Default Editor") {
        store.send(.openDefaultForCurrentWorktreeRequested)
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
}
