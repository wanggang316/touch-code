# Product Spec: Space Management

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-21

## Summary

A **Space** is touch-code's top-level workspace grouping — one Space per role or context (e.g. "day job", "side project", "research"). Users manage multiple Spaces and switch between them in the main window; each Space owns its own set of Projects and remembers which Project/Worktree was last active so returning to a Space feels like walking back into the same room. This spec covers full Space lifecycle management: creating, renaming, reordering, deleting, and switching. Space is a pure organizational concept — **no git, no filesystem, no external tooling**; it is a labeled bucket of Projects persisted to `catalog.json`.

## User Stories

- As a multi-context developer, I want to group Projects into Spaces (e.g. work / side / research) so that unrelated contexts stay visually and cognitively separate.
- As a user switching contexts, I want a one-click Space switcher at the bottom of the sidebar so I always know which Space I'm in and can jump between them without menu-diving.
- As a returning user, I want the Space I last worked in to reopen automatically on launch, with its last-active Project and Worktree restored.
- As a user reorganizing my setup, I want to rename, reorder, and delete Spaces from a manager surface.
- As a first-time user, I want a sensible default Space created for me so the app is usable without any setup.

## Requirements

### Must Have

- [ ] **First-run default Space.** On first launch (catalog empty), create a single Space named **"Personal"** and select it.
- [ ] **Create Space** from the Space switcher popover: prompts for a name; min 1 char, max 64 chars, trimmed. Duplicate names are allowed (users can disambiguate themselves); uniqueness is by UUID, not name.
- [ ] **Rename Space** inline in the Space manager; same validation as Create.
- [ ] **Reorder Spaces** by drag in the Space manager; persisted order is honored by the switcher and all Space lists.
- [ ] **Delete Space** with confirmation. **Always requires confirmation, regardless of contents.** Deleting a Space cascades to its Projects and Worktrees *in touch-code's data only* — the Project's on-disk git repos and worktree directories are **never touched**. The last remaining Space cannot be deleted (the UI suppresses the action and shows a hint).
- [ ] **Switch Space** from the sidebar bottom switcher. Switching is immediate (no progress UI) and restores:
  - the Space's last-selected Project and Worktree,
  - the Worktree's tabs and panels,
  - the Worktree's git-viewer visibility (unchanged from T1–T3 behavior).
- [ ] **Active Space persistence.** The currently active Space is recorded in `catalog.json` and restored on next launch.
- [ ] **Last-active Worktree per Space.** Each Space remembers the Worktree the user was on when they last left it; switching back restores that Worktree (falls back to Project's `selectedWorktreeID` if the recorded Worktree was removed — the model already handles this).
- [ ] **Space manager surface.** A dedicated sheet or popover listing all Spaces with per-row rename / delete / reorder affordances. Reachable from the Space switcher ("Manage Spaces…").
- [ ] **Single-window model.** v1 has one main window. Space selection is window-scoped but because there is only one window, it is effectively global. No "New Window" command in v1.

### Nice to Have

- [ ] **Space icon / emoji.** One-character visual prefix (e.g. 💼 / 🏠 / 🧪) chosen at create/rename time.
- [ ] **Keyboard shortcut for Space switch.** `⌘1`…`⌘9` jumps to the Nth Space; `⌘⇧{` / `⌘⇧}` cycles previous / next Space.
- [ ] **Duplicate-name warning.** Non-blocking inline hint when creating/renaming to a name that already exists in the list.

## Acceptance Criteria

- **Given** a fresh install with no `catalog.json`, **when** the app launches, **then** a Space named "Personal" exists, is selected, and is empty of Projects.
- **Given** a user with two Spaces, **when** they click the switcher and choose the other Space, **then** the sidebar Project list updates within one frame and the detail area restores the target Space's last Worktree and its tabs/panels.
- **Given** Space A has a last-active Worktree `feature/x`, **when** the user switches to Space B and later switches back to Space A, **then** `feature/x` is re-selected and its terminal state is restored.
- **Given** a user tries to delete the only remaining Space, **when** they open the Space manager, **then** the delete action on that row is disabled with a tooltip ("at least one Space must exist").
- **Given** a Space with 3 Projects and 5 Worktrees, **when** the user confirms deletion, **then** those Projects and Worktrees disappear from touch-code and the on-disk repositories and worktree directories are untouched (verified by listing the filesystem after deletion).
- **Given** a user renames a Space to an empty string, **when** they confirm, **then** the rename is rejected with an inline error and the prior name is preserved.
- **Given** the user reorders Spaces and quits the app, **when** they relaunch, **then** the switcher shows the new order.

## Scope

### In Scope

- Full CRUD (create, rename, reorder, delete) for Spaces.
- Space switcher UI in the sidebar and a Space manager surface.
- Active-Space persistence across launches; per-Space last-active Worktree memory.
- Cascade behavior on Space deletion (touch-code data only).

### Out of Scope (v1)

- **Multi-window support** — deferred; v1 is single-window. Listed in Future Consideration.
- **Moving Projects between Spaces** — a Project belongs to one Space for its lifetime in v1; to relocate, remove and re-add.
- **Sharing / syncing Spaces across machines** — local-only product.
- **Space-level preferences** (e.g. per-Space default editor) — global + per-Project preferences are enough in v1.
- **Per-Space agent notifications routing / filters** — aggregation is app-global in v1.

### Future Consideration

- Multi-window, with window ↔ Space 1:1 (see architecture Open Q #2).
- Drag-and-drop a Project across Spaces.
- Space templates ("clone current Space's Projects into a new Space").

## Design

This spec intentionally describes product behavior only. Data model (`Space`, `SpaceID`, `lastActiveWorktreeID`) already exists in `TouchCodeCore/Space.swift` and is sufficient for v1.

Reference projects have no equivalent concept — supacode and supaterm both operate on a single flat Repository list. Space is touch-code's addition.

Implementation details (Space switcher popover, Space manager sheet, persistence hand-off) will be covered in a follow-up design doc once this spec is approved.

## Open Questions

1. **Space manager surface shape** — popover from the switcher, or a sheet, or a dedicated section in Settings? *Leaning:* popover on the switcher (consistent with T1 sidebar).
2. **Delete-Space confirmation copy** — show Project/Worktree counts in the confirmation ("This will remove 3 Projects and 7 Worktrees from touch-code. Files on disk are not affected.")? *Leaning:* yes — users often forget what's inside.
3. **First-run Space name** — "Personal" (current leaning) vs. the user's login name vs. "Workspace". *Leaning:* "Personal" — neutral and obviously editable.
