# Changelog

All notable changes to touch-code are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project does not yet follow semantic versioning — every release until
1.0 is a developer build. Releases are dated.

## [Unreleased] — refactor/rm-space

### Removed

- **Spaces.** The top-level workspace grouping is gone. Projects are now
  the top-level row in the sidebar; the prior 5-level hierarchy
  (Space → Project → Worktree → Tab → Pane) collapses to 4 levels
  (Project → Worktree → Tab → Pane). Existing v2 catalogs are migrated
  losslessly: each Space becomes a same-named Tag (Finder-palette color
  cycled by Space order), and every Project that lived in that Space
  inherits the Tag. The previously-active Space (`Catalog.selectedSpaceID`,
  or the first window's selection) becomes the initial filter on
  `Catalog.activeTagFilter`.
- **Multi-window.** The main scene is now `Window(id: "main")` instead of
  `WindowGroup`. The `WindowGroup` allowed users to spawn extra main
  windows from the system menu, but no in-app surface ever consumed
  multi-window state. Settings remains a separate `Window(id: "settings")`,
  unchanged.
- **`tc space *` subcommands** — `list`, `create`, `activate`, `rename`,
  `remove`. Use `tc tag` for label-based classification.
- **Keyboard shortcuts ⌘K (Switch Space) and ⌘1–⌘9 (jump to Nth Space).**
  The slots are unbound for now; future work may rebind them to Tag
  filters or other features.
- **`hierarchy.{listSpaces,describeSpace,createSpace,renameSpace,removeSpace,activateSpace}`**
  IPC methods.
- **Hook envelope `space` anchor** (`HookEnvelope.space: SpaceRef?`) and
  the corresponding `HookScope.space` case. Hook handlers consuming
  `envelope.space.*` template fields (`space.id`, `space.name`) need
  to be updated — those fields no longer exist.

### Added

- **Tags as cross-cutting Project classification.** Each Project carries
  zero or more Tags (name + Finder-palette color). The sidebar can be
  filtered by an active Tag set with OR semantics; `[All]`,
  `[Untagged]`, and per-Tag chips live in a footer at the sidebar's
  safe-area bottom (the slot the prior Space footer occupied).
- **Tag CRUD UI** — right-click a Project → Tags → Edit Tags…, or click
  the chip footer's edit affordance, opens the TagManager sheet (rename
  inline, recolor via swatch, remove with cascade-count confirmation).
- **`tc tag` and `tc project tag` CLI** —
  `tc tag list/create/rename/recolor/remove`,
  `tc project tag add/remove`,
  `tc project list [--tag <id|name>] [--untagged]`.
- **`hierarchy.{listTags,createTag,renameTag,recolorTag,removeTag,setProjectTags,setActiveTagFilter}`**
  IPC methods.
- **⌘F focuses the chip footer** for keyboard-driven Tag filtering.
- **⌘Q confirmation dialog.** Quitting prompts when at least one Pane is
  open across any Worktree of any Project; the alert is suppressed on
  empty-state quit (no nag for users without a session).
- **⌘W hides the main window** (`applicationShouldTerminateAfterLastWindowClosed: false`);
  the app stays running in the dock with IPC + Ghostty surfaces alive.
  Re-clicking the dock icon re-shows the window.

### Changed

- **`catalog.json` schema bumped to v3.** v3 readers accept v1, v2, v3
  payloads (chained migration). v2 → v3 normalizes the version field
  in-memory; the next save writes v3 shape. Downgrading a v3 catalog
  to a pre-rm-space build will fail with `unsupportedVersion(3)` —
  restore from a backup.
- **`HookEnvelope` v1 wire shape changes** — `space` field removed.
  Hook handlers should drop any `envelope.space.*` references.

### Migration

The catalog migration runs once on first launch of the new build. A
backup of the prior catalog is not made automatically — users who want
a rollback path should copy `~/.config/touch-code/catalog.json` aside
before running the new build.
