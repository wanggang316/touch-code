# Changelog

All notable changes to touch-code are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project does not yet follow semantic versioning — every release until
1.0 is a developer build. Releases are dated.

## [Unreleased]

### Added

- **Add Project picker can create new folders inline** — the open-panel
  now permits directory creation, so first-time setups don't need to
  pre-make the project directory in Finder.
- **Folder → git auto-promotion.** A folder Project added before
  `git init` / `git clone` is now re-detected as a git repository on
  the next window-focus pulse and its `gitRoot` is persisted. The
  Project gains `+ Add Worktree` and the worktree reconcile path
  without an app restart.

### Changed

- **Worktree "executing" indicator** moved onto the worktree icon slot
  in the sidebar (replaces the previous inline location next to the
  worktree name).
- **ProjectReconciler debounce** raised from 2s to 10s. Window-focus
  freshness still works, but rapid cmd-tab cycles no longer re-scan
  large catalogs every pass.

### Removed

- **Inline loading spinner in Project header.** The reconcile pass is
  fast enough that the brief `ProgressView` next to the Project name
  was visual noise; it flashed on every focus pulse without conveying
  progress.

### Fixed

- **⌘⌫ / ⌘⇧⌫ can no longer archive or delete the main worktree
  checkout.** The sidebar context menu already hid these actions, but
  the destructive chords bypassed the guard. Lifecycle entry points
  now reject archive/remove on the worktree whose path equals
  `project.rootPath`.
- **⌘⌫ / ⌘⇧⌫ are gated on sidebar focus.** When a Ghostty pane holds
  first-responder, the menu items disable and the chord falls through
  to the terminal — restoring the standard ⌘⌫ "delete to start of
  line" in shells and editors.
