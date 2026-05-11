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
/// - `Open PR on GitHub` lives on `⌘⌃G` rather than `⌘⇧G` so it doesn't shadow AppKit's
///   default "Find Previous" chord in editable-text contexts (Settings panes, palette
///   query, hotkey recorder, etc.). In-GitViewer keybindings (`j / k / g / G / …`) gate
///   on `press.modifiers.isEmpty` and are never shadowed by these ⌘-modified chords.
/// - The app delegate guards `⌘Q` quit with a confirmation when running terminal sessions
///   exist. The chord itself is the standard AppKit one and is not registered with the
///   shortcut registry — quitting is a system-level action, not a rebindable in-app command.
struct MainWindowCommands: Commands {
  let store: () -> StoreOf<RootFeature>?
  /// Snapshot of the live `ShortcutsStore.resolved` map. Re-injected from `TouchCodeApp.body`
  /// on every render; SwiftUI's `Commands` participates in observation, so an override
  /// rebinds the menu items without a manual refresh path.
  let shortcuts: ResolvedShortcutMap
  /// First-responder tracker for sidebar focus. Drives `.disabled` on the destructive
  /// worktree chords (`⌘⌫` Archive / `⌘⇧⌫` Delete) so they only fire while the sidebar
  /// holds focus — when a Ghostty terminal pane is focused the menu items are disabled
  /// and the chord falls through to the terminal (where `⌘⌫` is the standard
  /// "delete to start of line" binding). Without this gate the chord would archive the
  /// active worktree any time the user pressed it inside the terminal.
  let sidebarFocus: SidebarFocusObserver
  /// Settings store reference — used by the Update Channel submenu so flipping channel
  /// from the menu writes through the same single-writer path as the Settings pane.
  /// `Commands` participates in `@Observable` tracking, so the menu's checkmark follows
  /// `settingsStore.settings.general.updateChannel` without manual refresh.
  let settingsStore: SettingsStore

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Quick Action…") {
        store()?.send(.commandPaletteToggle(nil))
      }
      .appKeyboardShortcut(.commandPaletteToggle, in: shortcuts)
      .disabled(store() == nil)

      Divider()

      Button("Open in Editor") {
        store()?.send(.openDefaultForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.openInEditor, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Toggle Git Viewer") {
        store()?.send(.diffInspectorToggledForCurrentWorktree)
      }
      .appKeyboardShortcut(.toggleDiffInspector, in: shortcuts)
      .disabled(!hasActiveWorktree)

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

      Divider()

      Button("Reveal in Finder") {
        store()?.send(.revealCurrentWorktreeInFinderRequested)
      }
      .appKeyboardShortcut(.revealCurrentWorktreeInFinder, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Copy Worktree Path") {
        store()?.send(.copyCurrentWorktreePathRequested)
      }
      .appKeyboardShortcut(.copyCurrentWorktreePath, in: shortcuts)
      .disabled(!hasActiveWorktree)

      // Archive / Delete are gated on `sidebarFocus.isSidebarFocused` so the chord
      // (`⌘⌫` / `⌘⇧⌫`) only fires while the sidebar holds first-responder. When a
      // Ghostty pane is focused the menu item is disabled, the menu's chord matcher
      // skips it, and the keystroke reaches the terminal — preserving the standard
      // `⌘⌫` "delete to start of line" binding inside running shells / editors.
      Button("Archive Worktree") {
        store()?.send(.archiveCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.archiveCurrentWorktree, in: shortcuts)
      .disabled(!hasActiveWorktree || !sidebarFocus.isSidebarFocused)

      Button("Delete Worktree") {
        store()?.send(.deleteCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.deleteCurrentWorktree, in: shortcuts)
      .disabled(!hasActiveWorktree || !sidebarFocus.isSidebarFocused)

      Button("Show Archived Worktrees") {
        store()?.send(.showArchivedWorktreesForCurrentProjectRequested)
      }
      .appKeyboardShortcut(.showArchivedWorktrees, in: shortcuts)
      .disabled(!hasCurrentProject)

      Divider()

      Button("Toggle Sidebar") {
        store()?.send(.toggleSidebarRequested)
      }
      .appKeyboardShortcut(.toggleSidebar, in: shortcuts)
      .disabled(store() == nil)

      Button("Reveal in Sidebar") {
        store()?.send(.revealCurrentWorktreeInSidebarRequested)
      }
      .appKeyboardShortcut(.revealCurrentWorktreeInSidebar, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Select Previous Worktree") {
        store()?.send(.selectAdjacentWorktreeRequested(.previous))
      }
      .appKeyboardShortcut(.selectPreviousWorktree, in: shortcuts)
      .disabled(store() == nil)

      Button("Select Next Worktree") {
        store()?.send(.selectAdjacentWorktreeRequested(.next))
      }
      .appKeyboardShortcut(.selectNextWorktree, in: shortcuts)
      .disabled(store() == nil)

      Divider()

      Button("Back") {
        store()?.send(.worktreeHistoryBackRequested)
      }
      .appKeyboardShortcut(.worktreeHistoryBack, in: shortcuts)
      .disabled(!hasHistoryBack)

      Button("Forward") {
        store()?.send(.worktreeHistoryForwardRequested)
      }
      .appKeyboardShortcut(.worktreeHistoryForward, in: shortcuts)
      .disabled(!hasHistoryForward)
    }

    // Check for Updates… lives next to the app menu's About / Settings group.
    // The Update Channel submenu sits inside the same group so the menu reads as a
    // single Updates cluster — flipping the channel from here writes through
    // `SettingsStore` and replays `UpdatesClient.applyPreferences(...)` so the running
    // Sparkle instance immediately picks up the new channel + interval.
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") {
        store()?.send(.checkForUpdatesRequested)
      }
      .appKeyboardShortcut(.checkForUpdates, in: shortcuts)
      .disabled(store() == nil)

      Picker("Update Channel", selection: updateChannelBinding) {
        Text("Stable").tag(UpdateChannel.stable)
        Text("Tip").tag(UpdateChannel.tip)
      }
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

      Divider()

      Button("Focus Left Split") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .left))
      }
      .appKeyboardShortcut(.focusSplitLeft, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Focus Right Split") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .right))
      }
      .appKeyboardShortcut(.focusSplitRight, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Focus Split Above") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .up))
      }
      .appKeyboardShortcut(.focusSplitUp, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Focus Split Below") {
        store()?.send(.focusAdjacentPaneInCurrentTabRequested(direction: .down))
      }
      .appKeyboardShortcut(.focusSplitDown, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Rename Tab…") {
        store()?.send(.renameActiveTabForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.renameActiveTab, in: shortcuts)
      .disabled(!hasActiveWorktree)

      Button("Change Tab Color…") {
        store()?.send(.changeActiveTabColorForCurrentWorktreeRequested)
      }
      .appKeyboardShortcut(.changeActiveTabColor, in: shortcuts)
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

  /// Drive `.disabled` on Back/Forward menu items so the chord is a hard
  /// no-op when there's no entry to navigate to (also dims the menu item).
  private var hasHistoryBack: Bool {
    !(store()?.state.navigationHistoryBack.isEmpty ?? true)
  }

  private var hasHistoryForward: Bool {
    !(store()?.state.navigationHistoryForward.isEmpty ?? true)
  }

  /// `true` when there is a selected Project. Drives `.disabled` for "New Worktree…".
  /// Doesn't gate on `gitRoot` (non-git Project ⇒ chord silently no-ops in the reducer)
  /// because exposing that gating in the Commands struct would require a
  /// `HierarchyManager` snapshot read — which inside SwiftUI `Commands` resolves against
  /// `liveValue` and crashes (PR-#13 trap). Reducer's guard is sufficient.
  private var hasCurrentProject: Bool {
    store()?.state.selection.projectID != nil
  }

  /// Two-way binding for the Update Channel `Picker` in the menu bar. Writes go through
  /// the same `SettingsStore` setter the Updates pane uses, then replay the full
  /// preference triple to Sparkle so the running updater picks up the new channel +
  /// matching `updateCheckInterval` immediately. `triggerBackgroundCheck: true` mirrors
  /// the pane's behavior — flipping channel implies "I want to see what's there now".
  private var updateChannelBinding: Binding<UpdateChannel> {
    Binding(
      get: { settingsStore.settings.general.updateChannel },
      set: { newValue in
        settingsStore.setUpdateChannel(newValue)
        let g = settingsStore.settings.general
        UpdatesClient.liveValue.applyPreferences(
          g.updateChannel,
          g.updatesAutomaticallyCheckForUpdates,
          g.updatesAutomaticallyDownloadUpdates,
          true
        )
      }
    )
  }
}
