import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Main-window menu commands. Every chord is sourced from the shortcut registry
/// (`ShortcutSchema.app` ⊕ `ShortcutsStore.overrides`) by way of the `appKeyboardShortcut`
/// modifier — defaults match what was previously hardcoded inline, but a user can rebind
/// any of them via Settings → Shortcuts and the menu rebinds without restart.
///
/// `store` is a closure rather than the resolved `Store` because this `Commands` struct is
/// instantiated once at scene build, before `AppState.bringUp()` has produced the live
/// store. Reading the store lazily on each button press lets the parent render
/// `MainWindowCommands` unconditionally — see the matching note in `TouchCodeApp.body`.
///
/// Collision notes for the registry-default chords below:
///
/// - `⌘⇧G` shadows AppKit's default "Find Previous" in editable-text contexts. The app has
///   no editable text fields at the window scope today, so the menu binding wins in the
///   common case. In-GitViewer keybindings (`j / k / g / G / …`) gate on
///   `press.modifiers.isEmpty` and are never shadowed by these ⌘-modified chords.
/// - The app delegate guards `⌘Q` quit with a confirmation when running terminal sessions
///   exist; the registry tracks `.quit` as `.systemFixed` for display only.
struct MainWindowCommands: Commands {
  let store: () -> StoreOf<RootFeature>?
  /// Snapshot of the live `ShortcutsStore.resolved` map. Re-injected from `TouchCodeApp.body`
  /// on every render; SwiftUI's `Commands` participates in observation, so an override
  /// rebinds the menu items without a manual refresh path.
  let shortcuts: ResolvedShortcutMap

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Quick Action…") {
        store()?.send(.commandPaletteToggle(nil))
      }
      .appKeyboardShortcut(.commandPaletteToggle, in: shortcuts)
      .disabled(store() == nil)

      Divider()

      Button("Open in Default Editor") {
        store()?.send(.openDefaultForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.openInDefaultEditor, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Toggle Git Viewer") {
        store()?.send(.diffInspectorToggledForCurrentWorktree)
      }
      .appKeyboardShortcut(.toggleDiffInspector, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Filter Tags") {
        store()?.send(.sidebar(.tagFilterFocusRequested))
      }
      .appKeyboardShortcut(.filterTags, in: shortcuts)
      .disabled(store() == nil)

      Button("Add Project…") {
        store()?.send(.sidebar(.toolbarAddProjectTapped))
      }
      .appKeyboardShortcut(.addProject, in: shortcuts)
      .disabled(store() == nil)

      Button("New Worktree…") {
        store()?.send(.newWorktreeForCurrentProjectRequested)
      }
      .appKeyboardShortcut(.newWorktree, in: shortcuts)
      .disabled(!hasCurrentProject)

      Button("Open PR on GitHub") {
        store()?.send(.openCurrentPRRequested)
      }
      .appKeyboardShortcut(.openCurrentPR, in: shortcuts)
      .disabled(!hasPRForCurrentWorktree)
    }

    // Tab-bar uplift (M2-T2.9). Lands in its own CommandGroup — placed
    // after the existing block so it reads as a second top-level group in
    // the menu bar rather than inflating the first group's fan-out. Tabs
    // take `⌥⌘1..⌥⌘9` (the prior `⌘1..⌘9` Space-switching bindings were
    // removed in M2).
    CommandGroup(after: .newItem) {
      Button("New Tab") {
        store()?.send(.newTabForCurrentWorktree)
      }
      .appKeyboardShortcut(.newTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Split Right") {
        store()?.send(.splitCurrentPaneRequested(direction: .right))
      }
      .appKeyboardShortcut(.splitRight, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Split Down") {
        store()?.send(.splitCurrentPaneRequested(direction: .down))
      }
      .appKeyboardShortcut(.splitDown, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Close Tab") {
        // ⌘W is global menu chord; SwiftUI Commands aren't scene-scoped, so the
        // same accelerator fires regardless of which window is key. Route on the
        // current key window: Settings (or any future SwiftUI utility window
        // tagged via `SettingsWindowTagger`) closes itself; the main `touch-code`
        // window forwards to TabFeature. Without this dispatch the chord pressed
        // inside Settings would close the foreground worktree's tab.
        if let key = NSApp.keyWindow, SettingsWindowTagger.matches(key) {
          key.performClose(nil)
        } else {
          store()?.send(.closeActiveTabForCurrentWorktree)
        }
      }
      .appKeyboardShortcut(.closeTab, in: shortcuts)
      .disabled(store() == nil)

      Divider()

      Button("Previous Tab") {
        store()?.send(.selectAdjacentTabForCurrentWorktree(.previous))
      }
      .appKeyboardShortcut(.previousTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Next Tab") {
        store()?.send(.selectAdjacentTabForCurrentWorktree(.next))
      }
      .appKeyboardShortcut(.nextTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Divider()

      ForEach(1...10, id: \.self) { n in
        if let id = CommandID.switchToTab(index: n) {
          Button("Switch to Tab \(n)") {
            store()?.send(.selectTabAtIndexForCurrentWorktree(n))
          }
          .appKeyboardShortcut(id, in: shortcuts)
          .disabled(!hasActiveWorktree)
        }
      }
    }
  }

  private var hasActiveWorktree: Bool {
    store()?.state.selection.worktreeID != nil
  }

  /// `true` when the current Worktree has a PR snapshot in the GitHub feature's cache.
  /// Drives the `.disabled` state of the "Open PR on GitHub" menu item — a Worktree
  /// without a fetched PR (non-GitHub repo, fresh branch with no PR yet, GitHub auth
  /// not configured) silently exposes a useless chord otherwise.
  private var hasPRForCurrentWorktree: Bool {
    guard
      let worktreeID = store()?.state.selection.worktreeID,
      store()?.state.gitHub.snapshots[worktreeID] != nil
    else { return false }
    return true
  }

  /// `true` when there is a selected Project. Drives `.disabled` for "New Worktree…".
  /// Doesn't gate on `gitRoot` (non-git Project ⇒ chord silently no-ops in the reducer)
  /// because exposing that gating in the Commands struct would require a
  /// `HierarchyManager` snapshot read — which inside SwiftUI `Commands` resolves against
  /// `liveValue` and crashes (PR-#13 trap). Reducer's guard is sufficient.
  private var hasCurrentProject: Bool {
    store()?.state.selection.projectID != nil
  }
}
