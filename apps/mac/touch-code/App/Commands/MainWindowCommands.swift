import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Main-window menu commands. Every chord is sourced from the shortcut registry
/// (`ShortcutSchema.app` ⊕ `ShortcutsStore.overrides`) by way of the `appKeyboardShortcut`
/// modifier — defaults match what was previously hardcoded inline, but a user can rebind
/// any of them via Settings → Shortcuts and the menu rebinds without restart.
///
/// Collision notes for the registry-default chords below:
///
/// - `⌘E` (Open in Default Editor) and `⌘⇧G` (Toggle Git Viewer) shadow AppKit defaults
///   ("Use Selection for Find" / "Find Previous") in editable-text contexts. The app has no
///   editable text fields at the window scope today, so the menu binding wins in the common
///   case. In-GitViewer keybindings (`j / k / g / G / …`) gate on `press.modifiers.isEmpty`
///   and are never shadowed by these ⌘-modified chords.
/// - The app delegate guards `⌘Q` quit with a confirmation when running terminal sessions
///   exist; the registry tracks `.quit` as `.systemFixed` for display only.
struct MainWindowCommands: Commands {
  let store: StoreOf<RootFeature>
  /// Snapshot of the live `ShortcutsStore.resolved` map. Re-injected from `TouchCodeApp.body`
  /// on every render; SwiftUI's `Commands` participates in observation, so an override
  /// rebinds the menu items without a manual refresh path.
  let shortcuts: ResolvedShortcutMap

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Quick Action…") {
        store.send(.commandPaletteToggle(nil))
      }
      .appKeyboardShortcut(.commandPaletteToggle, in: shortcuts)

      Divider()

      Button("Open in Default Editor") {
        store.send(.openDefaultForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.openInDefaultEditor, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Toggle Git Viewer") {
        store.send(.diffInspectorToggledForCurrentWorktree)
      }
      .appKeyboardShortcut(.toggleDiffInspector, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Filter Tags") {
        store.send(.sidebar(.tagFilterFocusRequested))
      }
      .appKeyboardShortcut(.filterTags, in: shortcuts)
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
      .appKeyboardShortcut(.newTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Close Tab") {
        store.send(.closeActiveTabForCurrentWorktree)
      }
      .appKeyboardShortcut(.closeTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      Button("Previous Tab") {
        store.send(.selectAdjacentTabForCurrentWorktree(.previous))
      }
      .appKeyboardShortcut(.previousTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Next Tab") {
        store.send(.selectAdjacentTabForCurrentWorktree(.next))
      }
      .appKeyboardShortcut(.nextTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      ForEach(1...9, id: \.self) { n in
        if let id = CommandID.switchToTab(index: n) {
          Button("Switch to Tab \(n)") {
            store.send(.selectTabAtIndexForCurrentWorktree(n))
          }
          .appKeyboardShortcut(id, in: shortcuts)
          .disabled(!hasActiveWorktree)
        }
      }
    }
  }

  private var hasActiveWorktree: Bool { store.state.selection.worktreeID != nil }
}
