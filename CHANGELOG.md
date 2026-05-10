# Changelog

All notable changes to touch-code are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project does not yet follow semantic versioning — every release until
1.0 is a developer build. Releases are dated.

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.1.6] - 2026-05-10

### Added

- **Updates pane with channel selection.** New Settings → Updates view
  backed by Sparkle, with a stable/tip channel picker and
  auto-check/download toggles persisted across launches. Menu bar gains
  an Update Channel submenu for quick switching.
- **`tc read` command** prints the visible terminal buffer of a pane to
  stdout.
- **App icon in About window** replaces the generic terminal glyph.
- **Unfocused pane dim now mirrors Ghostty's `unfocused-split`
  appearance** for visual consistency.

### Changed

- **`tc` CLI surface redesigned.** `rpc` subcommand removed, `ls`
  renamed to `tree`, completions hidden, and output hierarchy aligned
  with the Prowl convention.
- **DMG install arrow redrawn as a chevron** to match macOS convention.

### Fixed

- **IPC socket responses no longer truncate on macOS 26.** Clear
  `O_NONBLOCK` on accepted client fds, defer connect to first send to
  dodge the EPIPE quirk, and set `SO_NOSIGPIPE` so write errors surface
  correctly.
- **Tab-bar trailing accessory buttons now show chord hints on hover.**
- **Settings scene receives `CommandKeyObserver`** — opening Updates no
  longer crashes.
- **Pane cursor follows focus on `gotoSplit` navigation** instead of
  lagging behind.
- **`tc tree` / `tc focus` show live working-directory paths** from the
  running Ghostty surface instead of stale state.
- **Archived worktrees hidden from `tc tree` output.**
- **Worktree display-name editing preserves user input** instead of
  reverting to the directory name.
- **DMG volume icon corners rounded with squircle mask.**
- **Appcast feed URL hidden in release builds of the Updates pane.**

## [0.1.5] - 2026-05-07

### Added

- **Drag files into terminal panes to insert shell-escaped paths.**
  Drop one or more files onto a Ghostty surface and their absolute
  paths are inserted at the cursor, properly quoted for the shell.
- **⌘⇧R renames the active tab.** Matches the existing context-menu
  rename action and works through the chord overlay.
- **Pane focus navigation commands.** New `CommandID` entries plus
  menu items for moving focus between panes within a tab, composable
  with the existing chord layer.
- **Keyboard shortcuts shown inline in worktree & project context
  menus** for discoverability without opening the chord overlay.
- **Tab-bar accessory buttons gain hover background and chord
  tooltips.** Each button now exposes its bound chord — resolved
  through the user's keybindings — on hover.
- **DMG installer customized** with a branded volume icon and
  side-by-side Applications layout, so first-launch matches the rest
  of the app.

### Changed

- **Unfocused panes in multi-pane tabs are now dimmed**, mirroring
  the focus treatment used elsewhere in the app.
- **Reveal in Finder rebound to ⌘⌥O**, freeing ⌘O for the project
  picker and matching macOS-wide convention.
- **Window occlusion forwarded to libghostty.** Background windows
  no longer waste GPU on terminal redraws.
- **App icon refreshed**; main-worktree sidebar icon swapped to a
  neutral `circle.circle` glyph that matches regular worktree rows
  in size and tint.

### Fixed

- **Swift 6 isolated-deinit cascade crash on close-tab.** Tab
  teardown no longer trips strict-concurrency deinit checks when
  `SurfaceInfo` is released from `PaneSurface`'s nonisolated deinit
  (an implicit main-actor hop double-freed the TaskLocal scope and
  tripped libmalloc).
- **`Pane.initialCommand` no longer persists across app restarts.**
  Previously a tab restored from disk could re-run its bootstrap
  command, replaying side effects.
- **IME candidate window now follows the cursor**, and backspace
  during composition is suppressed so it edits the candidate buffer
  rather than the terminal.
- **`git diff -M -C` duplicate destination paths** (copy + rename
  collisions) are handled cleanly instead of trapping the parser.

## [0.1.4] - 2026-05-06

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
