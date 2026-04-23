# ExecPlan: Main-Window T4 — Space Management

**Status:** Draft
**Author:** feat/space-mgmt child agent (with master)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a touch-code user can:

- Open a dedicated **Manage Spaces…** sheet from the sidebar Space-switcher popover that lets them rename, drag-reorder, and delete Spaces inline.
- On a fresh install (empty `catalog.json`), launch the app and immediately find a single Space named **"Personal"** — no empty-state onboarding required.
- Be prevented from deleting the only remaining Space — the trash affordance is disabled with a tooltip explaining why.
- Delete a non-terminal Space and see a confirmation dialog that lists how many Projects and Worktrees will be removed *from touch-code* ("Files on disk are not affected.") before proceeding.
- Press **⌘1**…**⌘9** to jump to the Nth Space in the sidebar order; the same outgoing/incoming `lastActiveWorktreeID` choreography the popover uses is reused so the active Worktree is restored.
- See a non-blocking inline warning when they rename a Space to a name another Space already uses (duplicates are allowed; the hint is informational).

The Space data model is unchanged — every required field (`Space.lastActiveWorktreeID`, `Catalog.spaces` order, `Catalog.selectedSpaceID`) already exists and is honored by T0–T3 code. This plan only adds the UI surface, one manager method (`reorderSpaces`), one client closure (`reorderSpaces`), and a first-run seed branch in the app bootstrap.

## Progress

- [ ] M0 — Baseline: rebase `feat/space-mgmt` onto latest `feature/hierarchy-management`, confirm lint + existing tests green before any edit
- [ ] M1 — Manager + Client: `HierarchyManager.reorderSpaces` + matching `HierarchyClient.reorderSpaces` closure (append-only per master's parallel-conflict rule)
- [ ] M2 — First-run seed: `TouchCodeApp.init` seeds "Personal" when `catalog.spaces.isEmpty`
- [ ] M3 — `SpaceManagerFeature` reducer: list / rename / reorder / delete state + actions + reducer branches
- [ ] M4 — `SpaceManagerView`: sheet UI with `.onMove` drag-reorder, inline rename, confirmation dialog, last-Space guard
- [ ] M5 — Root + Sidebar wiring: `.sidebar(.delegate(.openSpaceManager))` → `RootFeature.@Presents spaceManagerSheet` → hosted via `.sheet(item:)` in `ContentView` (SettingsSheet pattern)
- [ ] M6 — Popover entry: "Manage Spaces…" row added at the end of `spacePopover(catalog:)` that dismisses the popover and fires the delegate
- [ ] M7 — ⌘1–⌘9: extend `MainWindowCommands` + `RootFeature.Action.switchToSpaceAtIndex(Int)` reusing `handleSpaceSwitch` semantics
- [ ] M8 — Tests: `SpaceManagerFeatureTests` + extended `HierarchySidebarFeatureTests` / `RootFeatureTests` + `HierarchyManager` reorder test + first-run seed test
- [ ] M9 — Manual QA, lint, full xcodebuild test, push, open PR against `feature/hierarchy-management`

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** (planning, 2026-04-21): Manager surface is a **sheet**, not a popover, despite the spec's popover leaning. Drag-reorder inside a narrow popover and the nested confirmation dialog both want stable parent chrome. The popover keeps a "Manage Spaces…" entry, so the popover-first discovery path is preserved (S-Q1 = a).
- **D2** (planning, 2026-04-21): Sheet state lives on **`RootFeature.@Presents spaceManagerSheet`**, mirroring `settingsSheet`. The sheet is window-modal and its effects span features (catalog mutation, terminal pane close via cascade), so it does not belong to `HierarchySidebarFeature`.
- **D3** (planning, 2026-04-21): **No schema change.** `Space.lastActiveWorktreeID`, `Catalog.spaces[]` order, and `Catalog.selectedSpaceID` already cover every product-spec requirement. Adding a parallel `displayOrder: [SpaceID]` would create a second source of truth for zero benefit.
- **D4** (planning, 2026-04-21): `reorderSpaces(fromOffsets:toOffset:)` takes the SwiftUI `.onMove(perform:)` payload shape directly (IndexSet + Int offset) so the reducer forwards unchanged. Silent no-op on empty `IndexSet` — matches the dedup pattern in `setSpaceLastActiveWorktree`.
- **D5** (planning, 2026-04-21): **Last-Space protection is double-gated.** View disables the trash button when `catalog.spaces.count == 1` (with tooltip); reducer also short-circuits `.removeConfirmed` on a single-Space catalog. A future keybinding or test path that bypasses the UI disable still cannot delete the last Space.
- **D6** (planning, 2026-04-21): Delete confirmation counts (`projectCount`, `worktreeCount`) are captured from the snapshot **at tap-time** on `PendingSpaceRemoval` rather than recomputed when the dialog renders. Same pattern as `PendingWorktreeRemoval.displayName` — the dialog text stays stable if the catalog mutates under a long-held confirmation.
- **D7** (planning, 2026-04-21): First-run seed runs in **`TouchCodeApp.init`** (the app-bootstrap layer), not in `HierarchyManager.init`. The manager is not opinionated about fallback content; several existing tests build `HierarchyManager` directly with empty catalogs and must not acquire an implicit "Personal" Space.
- **D8** (planning, 2026-04-21): Seed persistence rides the manager's existing 500 ms debounced save pipeline — no synchronous `saveNow`. If the app is force-killed within 500 ms of first launch the next launch reseeds, which is the safe default.
- **D9** (planning, 2026-04-21): ⌘1–⌘9 dispatches `RootFeature.Action.switchToSpaceAtIndex(Int)`, which resolves the index against `hierarchyClient.snapshot().spaces` and forwards to `.sidebar(.spaceRowTapped(id))` so the popover and keyboard paths share `handleSpaceSwitch`. Out-of-range indices are silent no-ops.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/space-management.md` — the authoritative 11 must-haves and acceptance-criteria matrix.
- Design doc: `docs/design-docs/mw-t4-space-management.md` — read in full before editing code; it contains the component-boundary rationale, the alternatives table, and the exact state / action shapes.
- Golden rules: `docs/golden-rules.md`.
- T0–T3 precedents: `docs/design-docs/mw-t0-foundation.md` (catalog schema), `docs/design-docs/mw-t1-sidebar.md` (sidebar / popover), `docs/design-docs/mw-t3-gitviewer-overlay-shortcuts.md` (`MainWindowCommands` + Presents-sheet pattern).

Key source files to read (in this order) before M1:

- `apps/mac/TouchCodeCore/Space.swift` — the model; no edits, but confirm `lastActiveWorktreeID` contract before wiring.
- `apps/mac/touch-code/Runtime/HierarchyManager.swift` — owns every mutation. `createSpace`, `renameSpace`, `removeSpace`, `selectSpace`, `setSpaceLastActiveWorktree` are the siblings of the new `reorderSpaces`. Lines 23–68 are the Space-mutation block; insert `reorderSpaces` right after `setSpaceLastActiveWorktree`.
- `apps/mac/touch-code/App/Clients/HierarchyClient.swift` — the TCA dependency surface. The new `reorderSpaces` closure is appended to the end of the property list (line ~92) and to the end of each factory (`live`, `liveValue`, `testValue`) per master's parallel-conflict rule. **Do not reorder existing fields.**
- `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — adds one action (`spacePopoverManageSpacesTapped`) and one Delegate case (`openSpaceManager`). `handleSpaceSwitch` at line 384 is reused verbatim by ⌘1–⌘9.
- `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarView.swift` — adds one `Button` to `spacePopover(catalog:)` under the existing `Divider()`. **Do not touch** the Add Project block at lines 66–71 or the Add Worktree block at lines 78–83 (master-flagged for T-PROJECT / T-WORKTREE).
- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — adds `@Presents var spaceManagerSheet`, two actions (`spaceManagerSheetShown`, `switchToSpaceAtIndex(Int)`), one delegate branch (`openSpaceManager`), one `.ifLet` at the bottom. Mirrors `settingsSheet` exactly.
- `apps/mac/touch-code/App/ContentView.swift` line 72 — the `.sheet(item:)` host for `settingsSheet`. A second identical `.sheet(item:)` is added for `spaceManagerSheet`.
- `apps/mac/touch-code/App/Commands/MainWindowCommands.swift` — `CommandGroup(after: .newItem)` currently binds ⌘E / ⌘⇧G / ⌘K. M7 appends a loop `ForEach(1...9)` of hidden buttons with `.keyboardShortcut("\(n)", modifiers: .command)`.
- `apps/mac/touch-code/App/TouchCodeApp.swift` lines 113–136 — `init()`. The seed branch sits between `catalogStore.load()` and `HierarchyManager(...)` construction.

Test targets:

- `apps/mac/touch-code/Tests/` — home for `SpaceManagerFeatureTests` (new file) and extensions to `HierarchySidebarFeatureTests` + `RootFeatureTests` + `MainWindowCommandsTests`.
- `apps/mac/TouchCodeCoreTests/` — home for a new `HierarchyManagerReorderTests` (or extend an existing sibling file; follow whatever placement `setSpaceLastActiveWorktree` currently has).

## Plan of Work

### Milestone 0 — Baseline

Before any edit, confirm the working tree is clean and the current build is healthy. Rebase `feat/space-mgmt` onto the latest `feature/hierarchy-management` so any T-PROJECT / T-WORKTREE merges that landed between Design and Execute are picked up. Run `make -C apps/mac lint` and `xcodebuild test -scheme touch-code`; capture any **pre-existing** lint or test failures so the post-work comparison is apples-to-apples. If unrelated failures exist, escalate via CLARIFY before touching code — do not silently inherit regressions.

### Milestone 1 — Manager + Client

Add `HierarchyManager.reorderSpaces(fromOffsets:toOffset:)` immediately after `setSpaceLastActiveWorktree`:

```swift
func reorderSpaces(fromOffsets source: IndexSet, toOffset destination: Int) {
  guard !source.isEmpty else { return }
  catalog.spaces.move(fromOffsets: source, toOffset: destination)
  store.scheduleSave(catalog)
}
```

In `HierarchyClient.swift`, append a new closure **at the end** of the property list (after `selectionChanges`):

```swift
var reorderSpaces: @MainActor @Sendable (_ source: IndexSet, _ destination: Int) -> Void
```

Append matching entries at the end of `live(manager:)`, `liveValue`, and `testValue` init lists. Append-only is load-bearing: T-PROJECT and T-WORKTREE children also touch this file and master's rule is "追加到文件末尾, 不改已有签名".

Verify by building: `xcodebuild build -scheme touch-code` must succeed. No behavior change visible yet.

### Milestone 2 — First-run seed

Edit `TouchCodeApp.init()`:

```swift
let catalogStore = CatalogStore()
let runtime = GhosttyBackedHierarchyRuntime()
var catalog = (try? catalogStore.load()) ?? .default
let needsSeed = catalog.spaces.isEmpty
if needsSeed {
  let seed = Space(name: "Personal")
  catalog.spaces = [seed]
  catalog.selectedSpaceID = seed.id
}
let manager = HierarchyManager(catalog: catalog, store: catalogStore, runtime: runtime)
if needsSeed { catalogStore.scheduleSave(manager.catalog) }
```

Verify by wiping `~/Library/.../catalog.json` (or running against a temp dir) and launching — the sidebar footer should read "Personal" and the Project list should be empty.

### Milestone 3 — `SpaceManagerFeature` reducer

Create `apps/mac/touch-code/App/Features/SpaceManager/SpaceManagerFeature.swift`:

```swift
@Reducer
struct SpaceManagerFeature {
  @ObservableState
  struct State: Equatable {
    var renameDraft: RenameDraft?
    var pendingRemoval: PendingSpaceRemoval?
  }

  struct RenameDraft: Equatable {
    var spaceID: SpaceID
    var text: String
  }

  struct PendingSpaceRemoval: Equatable {
    var spaceID: SpaceID
    var displayName: String
    var projectCount: Int
    var worktreeCount: Int
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case renameRowTapped(SpaceID, currentName: String)
    case renameDraftChanged(String)
    case renameCommitted
    case renameCancelled

    case removeTapped(SpaceID, name: String)
    case removeConfirmed
    case removeCancelled

    case reordered(IndexSet, Int)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> { … }
}
```

Reducer branches:

- `renameRowTapped` → parks `RenameDraft(spaceID, text: currentName)`.
- `renameDraftChanged(newText)` → mutates `state.renameDraft?.text`.
- `renameCommitted` → trim, guard non-empty, `try? hierarchyClient.renameSpace(draft.spaceID, trimmed)`, clear draft.
- `renameCancelled` → clear draft.
- `removeTapped(id, name)` → snapshot `hierarchyClient.snapshot()`, resolve the Space, capture `projectCount = space.projects.count` and `worktreeCount = space.projects.reduce(0) { $0 + $1.worktrees.count }`, park `PendingSpaceRemoval`.
- `removeConfirmed` → re-check `snapshot.spaces.count > 1` (D5 belt-and-suspenders), `try? hierarchyClient.removeSpace(pending.spaceID)`, clear `pendingRemoval`.
- `removeCancelled` → clear `pendingRemoval`.
- `reordered(source, dest)` → `hierarchyClient.reorderSpaces(source, dest)`.

### Milestone 4 — `SpaceManagerView`

Create `apps/mac/touch-code/App/Features/SpaceManager/SpaceManagerView.swift`. Read `HierarchyManager.catalog` via `@Environment` (same pattern as `HierarchySidebarView`). The body is a `NavigationStack { List { … }.toolbar { Done } }` hosted inside a sheet.

Each row:

```
┌────────────────────────────────────────────┐
│ ⋮⋮  Name / TextField     ⚠ dup-hint    🗑  │
└────────────────────────────────────────────┘
```

- Tap on text → enter rename. Focus a `TextField` when `store.renameDraft?.spaceID == space.id`; submit on `.onSubmit`, cancel on Escape (`keyboardShortcut(.cancelAction)` on an invisible Button if needed).
- The duplicate-name warning is a `.caption` Text shown *while editing* when the trimmed `renameDraft.text` matches another Space's name (case-sensitive; duplicates are legal, this is informational).
- Trash button dispatches `.removeTapped`. `.disabled(catalog.spaces.count == 1)` with `.help("At least one Space must exist")`.
- `.onMove { source, dest in store.send(.reordered(source, dest)) }` on the `ForEach`.

Confirmation dialog attached to the same view (not lifted to Root):

```swift
.confirmationDialog(
  pendingRemovalTitle,
  isPresented: Binding(
    get: { store.pendingRemoval != nil },
    set: { if !$0 { store.send(.removeCancelled) } }
  ),
  titleVisibility: .visible
) {
  Button("Remove Space", role: .destructive) { store.send(.removeConfirmed) }
  Button("Cancel", role: .cancel) { store.send(.removeCancelled) }
} message: {
  Text(pendingRemovalMessage)  // "This will remove N Project(s) and M Worktree(s) from touch-code. Files on disk are not affected."
}
```

A "Done" toolbar button fires `dismiss()` (via `@Dependency(\.dismiss)`).

Run `make -C apps/mac generate` if a new directory needs the Tuist buildable-folders scan; `buildableFolders` has recursed into new subdirs in the T3 precedent so a re-generate is usually a no-op.

### Milestone 5 — Root + Sidebar wiring

In `RootFeature.State`:

```swift
@Presents var spaceManagerSheet: SpaceManagerFeature.State?
```

New actions on `RootFeature.Action`:

```swift
case spaceManagerSheetShown
case spaceManagerSheet(PresentationAction<SpaceManagerFeature.Action>)
case switchToSpaceAtIndex(Int)
```

New Delegate case on `HierarchySidebarFeature.Action.Delegate`:

```swift
case openSpaceManager
```

Routing:

- Sidebar's `.delegate(.openSpaceManager)` → handled by `RootFeature` pattern-match branch `.sidebar(.delegate(.openSpaceManager))` → `return .send(.spaceManagerSheetShown)`.
- `.spaceManagerSheetShown` → `state.spaceManagerSheet = SpaceManagerFeature.State()`, `return .none`.
- `.spaceManagerSheet(.dismiss)` → `state.spaceManagerSheet = nil`, `return .none`.
- `.switchToSpaceAtIndex(n)` → resolves via `hierarchyClient.snapshot().spaces`; guard `0..<spaces.count` contains `n-1`; forwards to `.sidebar(.spaceRowTapped(spaces[n-1].id))`.

Append `.ifLet(\.$spaceManagerSheet, action: \.spaceManagerSheet) { SpaceManagerFeature() }` at the bottom of `body`, mirroring `settingsSheet`.

In `ContentView.swift`, after the existing `.sheet(item: $store.scope(state: \.settingsSheet, …))` (line 72):

```swift
.sheet(item: $store.scope(state: \.spaceManagerSheet, action: \.spaceManagerSheet)) { sheetStore in
  SpaceManagerView(store: sheetStore)
}
```

### Milestone 6 — Popover entry

In `HierarchySidebarFeature`:

```swift
case spacePopoverManageSpacesTapped

// reducer:
case .spacePopoverManageSpacesTapped:
  state.isSpacePopoverPresented = false
  return .send(.delegate(.openSpaceManager))
```

In `HierarchySidebarView.spacePopover(catalog:)`, under the existing `Divider()` and before the closing `VStack`:

```swift
Button {
  store.send(.spacePopoverManageSpacesTapped)
} label: {
  HStack(spacing: 8) {
    Image(systemName: "slider.horizontal.3").frame(width: 14)
    Text("Manage Spaces…")
    Spacer()
  }
  .padding(.horizontal, 12)
  .padding(.vertical, 6)
  .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

### Milestone 7 — ⌘1–⌘9

In `MainWindowCommands.swift`, inside `CommandGroup(after: .newItem)`:

```swift
ForEach(1...9, id: \.self) { n in
  Button("Switch to Space \(n)") {
    store.send(.switchToSpaceAtIndex(n))
  }
  .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
}
```

If any collision with existing `CommandGroup(after: .newItem)` buttons or with AppKit defaults shows up during manual QA, drop the ⌘1–⌘9 chunk from this PR (it is Nice-to-Have). Document the drop in Surprises & Discoveries.

### Milestone 8 — Tests

- `HierarchyManager` reorder test (new file or extend the neighbor that covers `setSpaceLastActiveWorktree`): create 3 Spaces, call `reorderSpaces(fromOffsets: IndexSet([2]), toOffset: 0)`, assert new order + `scheduleSave` fires (or assert via `store.latestCatalog`).
- `SpaceManagerFeatureTests` (new): rename trim+empty guard, remove captures counts, remove short-circuits on single-Space catalog, reorder forwards payload, rename forwards to client.
- `HierarchySidebarFeatureTests` (extend): `.spacePopoverManageSpacesTapped` sets `isSpacePopoverPresented = false` and emits `.delegate(.openSpaceManager)`.
- `RootFeatureTests` (extend): `.sidebar(.delegate(.openSpaceManager))` → `.spaceManagerSheetShown` → `state.spaceManagerSheet != nil`; `.spaceManagerSheet(.dismiss)` → `nil`. `.switchToSpaceAtIndex` resolves to the Nth Space and forwards to `.sidebar(.spaceRowTapped(id))` (out-of-range is no-op).
- First-run seed test: extend an existing `CatalogCodableTests`-sibling to load an empty catalog, run the seed logic (extract to a pure helper if needed for unit isolation), assert a single "Personal" Space is present.

### Milestone 9 — Push & PR

Run `make -C apps/mac lint` and `xcodebuild test -scheme touch-code` from `apps/mac`. Then:

```bash
git push -u origin feat/space-mgmt
gh pr create --base feature/hierarchy-management \
  --title "T4: Space management — manager sheet + first-run seed + ⌘1-9" \
  --body-file <(cat <<'EOF'
## Summary
- Space manager sheet (list / rename / drag-reorder / delete) reachable from the popover "Manage Spaces…" entry
- First-run seed of a single "Personal" Space when catalog.json is empty
- Last-Space protection (UI-disabled + reducer short-circuit)
- Delete confirmation shows cascade counts; files on disk untouched
- ⌘1-⌘9 Space switching reusing handleSpaceSwitch choreography
- Inline non-blocking duplicate-name hint while renaming

## Design
- docs/design-docs/mw-t4-space-management.md
- docs/exec-plans/mw-t4-space-management.md

## Test plan
- [ ] xcodebuild test -scheme touch-code — all green
- [ ] Manual: fresh install (wipe catalog.json) → "Personal" exists
- [ ] Manual: create two Spaces, rename, drag-reorder, delete non-last
- [ ] Manual: delete last Space → trash disabled + tooltip
- [ ] Manual: ⌘K → Manage Spaces… → sheet opens; ⌘1 / ⌘2 switch
- [ ] Manual: quit + relaunch → order + active Space persisted
EOF
)
```

Push PR URL back to master via prowl `PR_READY`.

## Concrete Steps

From the repo root `/Users/wanggang/.worktree/repos/touch-code/feat/space-mgmt`:

```bash
# M0
git fetch origin
git rebase origin/feature/hierarchy-management
make -C apps/mac lint | tee /tmp/lint-baseline.txt
xcodebuild -scheme touch-code test -destination 'platform=macOS' 2>&1 | tail -50

# After each milestone, re-run:
make -C apps/mac lint
xcodebuild -scheme touch-code build -destination 'platform=macOS'

# After M8:
xcodebuild -scheme touch-code test -destination 'platform=macOS' 2>&1 | tee /tmp/test-final.txt
grep -E "Test Suite.*passed|Test Suite.*failed" /tmp/test-final.txt
```

Commit cadence follows the `/commit` skill — one commit per completed milestone (master's durable instruction).

## Validation and Acceptance

Product-spec ACs, mapped to proof:

1. **Fresh install seeds "Personal"** — Delete `catalog.json` → launch → sidebar footer shows "Personal", Project list empty. Covered by M8 first-run test.
2. **Switcher restores last Worktree within one frame** — Existing T1 behavior; reducer test on `.switchToSpaceAtIndex` asserts forwarding into `.spaceRowTapped` which drives `handleSpaceSwitch`.
3. **A→B→A round-trip restores A's last Worktree** — Manual QA step; existing `handleSpaceSwitch` code path.
4. **Only-Space delete action disabled + tooltip** — Sheet trash button `.disabled(catalog.spaces.count == 1).help("…")`; reducer `.removeConfirmed` guard; M8 reducer test.
5. **Cascade removes data only, not files on disk** — `HierarchyManager.removeSpace` mutates catalog only; filesystem untouched. Manual QA: create a Space with a Project rooted at a temp dir, delete Space, `ls` the temp dir shows files intact.
6. **Empty rename rejected** — `renameCommitted` trim+empty guard; M8 reducer test.
7. **Reorder persists across restart** — `reorderSpaces` writes through `store.scheduleSave`. Manual QA: drag-reorder, quit, relaunch, order preserved.

Additional:

- **Popover entry opens the sheet** — M8 sidebar test + manual: click footer → "Manage Spaces…" → sheet.
- **⌘1–⌘9 switches** — M8 reducer test + manual: create 3 Spaces, press ⌘2 / ⌘3.
- **Duplicate-name inline hint** — Manual: rename Space A to "Personal" (existing), hint text appears while typing but commit succeeds.

## Idempotence and Recovery

Every milestone is repeatable. Key guards:

- `reorderSpaces` empty-IndexSet guard — safe to call with unchanged selection.
- First-run seed check `catalog.spaces.isEmpty` — only seeds when needed; re-running the branch on a populated catalog is a no-op.
- Rename dedup lives in `HierarchyManager.renameProject` precedent; `renameSpace` does not currently dedup but an unchanged name is a harmless write (debounce coalesces).
- If M5 wiring is partially applied (sheet state added but no `.sheet(item:)` host), the sheet state is dead but harmless — `spaceManagerSheet` stays `nil` until triggered.
- If a pre-commit lint hook fires mid-milestone, fix in place and create a **new** commit per master's git-safety rule (never `--amend`).

## Artifacts and Notes

Sample expected `reorderSpaces` behavior:

```swift
// before: [A, B, C]
manager.reorderSpaces(fromOffsets: IndexSet([2]), toOffset: 0)
// after:  [C, A, B]
```

Sample `PendingSpaceRemoval` capture:

```swift
let space = snapshot.spaces.first { $0.id == id }!
let pending = PendingSpaceRemoval(
  spaceID: id,
  displayName: space.name,
  projectCount: space.projects.count,
  worktreeCount: space.projects.reduce(0) { $0 + $1.worktrees.count }
)
```

Sample dialog message format:

> *Remove Space "Day Job"?*
>
> *This will remove 3 Projects and 7 Worktrees from touch-code. Files on disk are not affected.*

## Interfaces and Dependencies

In `apps/mac/touch-code/Runtime/HierarchyManager.swift`, add:

```swift
func reorderSpaces(fromOffsets source: IndexSet, toOffset destination: Int)
```

In `apps/mac/touch-code/App/Clients/HierarchyClient.swift` (appended to end of properties + factories):

```swift
var reorderSpaces: @MainActor @Sendable (_ source: IndexSet, _ destination: Int) -> Void
```

In `apps/mac/touch-code/App/Features/SpaceManager/SpaceManagerFeature.swift`, define `@Reducer struct SpaceManagerFeature` per Milestone 3 shape.

In `apps/mac/touch-code/App/Features/Root/RootFeature.swift`, extend `State` with `@Presents var spaceManagerSheet: SpaceManagerFeature.State?` and `Action` with `.spaceManagerSheetShown`, `.spaceManagerSheet(PresentationAction<SpaceManagerFeature.Action>)`, `.switchToSpaceAtIndex(Int)`. Extend `HierarchySidebarFeature.Action.Delegate` with `case openSpaceManager`.

In `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`, add `case spacePopoverManageSpacesTapped` and its reducer branch.

In `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarView.swift`, append one `Button` row to `spacePopover(catalog:)`. **No other edits in this file.**

In `apps/mac/touch-code/App/Commands/MainWindowCommands.swift`, append the `ForEach(1...9, …)` block inside the existing `CommandGroup(after: .newItem)`.

In `apps/mac/touch-code/App/ContentView.swift`, append a second `.sheet(item:)` for `spaceManagerSheet` after the `settingsSheet` one at line 72.

In `apps/mac/touch-code/App/TouchCodeApp.swift`, insert the seed branch between `catalogStore.load()` (line 116) and `HierarchyManager(...)` (line 117).

External dependencies: none added. All new code uses existing `ComposableArchitecture`, `SwiftUI`, `TouchCodeCore`, `Observation` imports.
