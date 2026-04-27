import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// T3 main-window shortcuts. Attached to the main `Window` in `TouchCodeApp`.
/// Binds:
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
      Button("Quick Action…") {
        store.send(.commandPaletteToggle(nil))
      }
      .keyboardShortcut(KeyEquivalent(CommandPaletteShortcut.keyChar), modifiers: .command)

      Divider()

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

      Button("Filter Tags") {
        store.send(.sidebar(.tagFilterFocusRequested))
      }
      .keyboardShortcut("f", modifiers: .command)
    }

    // Tab-bar uplift (M2-T2.9). Lands in its own CommandGroup — placed
    // after the existing block so it reads as a second top-level group in
    // the menu bar rather than inflating the first group's fan-out. Tabs
    // take `⌥⌘1..⌥⌘9` (the prior `⌘1..⌘9` Space-switching bindings were
    // removed in M2).
    CommandGroup(after: .newItem) {
      Button("New Tab") {
        store.send(.newTabForCurrentWorktree)
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(!hasActiveWorktree)

      Button("Close Tab") {
        store.send(.closeActiveTabForCurrentWorktree)
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(!hasActiveWorktree)

      Divider()

      Button("Previous Tab") {
        store.send(.selectAdjacentTabForCurrentWorktree(.previous))
      }
      .keyboardShortcut("[", modifiers: [.command, .shift])
      .disabled(!hasActiveWorktree)

      Button("Next Tab") {
        store.send(.selectAdjacentTabForCurrentWorktree(.next))
      }
      .keyboardShortcut("]", modifiers: [.command, .shift])
      .disabled(!hasActiveWorktree)

      Divider()

      ForEach(1...9, id: \.self) { n in
        Button("Switch to Tab \(n)") {
          store.send(.selectTabAtIndexForCurrentWorktree(n))
        }
        .keyboardShortcut(
          KeyEquivalent(Character("\(n)")),
          modifiers: [.command, .option]
        )
        .disabled(!hasActiveWorktree)
      }
    }
  }

  private var hasActiveWorktree: Bool { store.state.selection.worktreeID != nil }
}
