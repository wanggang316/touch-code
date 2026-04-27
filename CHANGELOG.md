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
  (Project → Worktree → Tab → Pane).
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

- **`catalog.json` schema bumped to v3.** **No backward compatibility:**
  the v3 reader rejects v1 and v2 payloads with `unsupportedVersion`. A
  user upgrading from a pre-rm-space build will need to delete (or
  hand-edit) `~/.config/touch-code/catalog.json` to launch the new
  build; a fresh v3 catalog will be written from defaults. Downgrading
  a v3 catalog back to a pre-rm-space build also fails-loud.
- **`HookEnvelope` wire bumped to v2.** v1 → v2 dropped the `space`
  anchor field and the `space.*` template paths. Hook handlers should
  drop any `envelope.space.*` references and check
  `envelope.version >= 2` if they read newer fields.

### Breaking

- Existing `catalog.json` files (v1 / v2) are not migrated; the new
  build refuses to read them. This is intentional — see Removed §
  catalog.json schema. Recommended path for upgraders: delete the file
  and re-add Projects via the sidebar's "Add Project" affordance.
