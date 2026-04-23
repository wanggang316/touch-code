# MW-T4 — Space Management

**Status:** Draft
**Author:** feat/space-mgmt child agent (with master)
**Date:** 2026-04-21
**Product spec:** [docs/product-specs/space-management.md](../product-specs/space-management.md)

## 1. Context

T0–T3 delivered the main window shell, sidebar tree, header, and git-viewer
overlay. The Space switcher popover T1 introduced supports *create* and
*switch* only; there is no surface for rename / reorder / delete, no
first-run seed, and the per-Space `lastActiveWorktreeID` field already on
the model is wired on row-tap + space-switch (see
`HierarchySidebarFeature.handleSpaceSwitch`) but not on the "Manage
Spaces…" flow the product spec now requires.

This design covers the remaining work needed to satisfy every Must-Have in
`docs/product-specs/space-management.md` plus two Nice-to-Haves that fit
cleanly into the same plumbing (⌘1–⌘9 switcher + duplicate-name
non-blocking warning). Space icon/emoji is deferred.

## 2. Goals

- Full CRUD for Spaces from a dedicated UI surface (sheet).
- First-run seed of a Space named "Personal" when the catalog is empty.
- Delete Space is confirmation-gated and shows cascade counts; the *last*
  Space cannot be deleted (UI suppresses the action).
- Popover gets a "Manage Spaces…" entry that opens the sheet
  (Open Question S-Q1 = a, settled by master).
- ⌘1–⌘9 jump to the Nth Space (Nice-to-Have; cheap given Commands already
  exists in `MainWindowCommands`).
- Per-Space `lastActiveWorktreeID` keeps working: no model change needed;
  the existing `handleSpaceSwitch` remains the canonical restore site.

## 3. Non-Goals

- Multi-window (spec out-of-scope).
- Moving Projects between Spaces.
- Per-Space icon / emoji (Nice-to-Have, deferred to keep scope tight).
- ⌘⇧{ / ⌘⇧} prev/next Space cycling (drops out cheaply if ⌘N switching
  lands; but not required for this PR).
- Schema changes to `Space` / `Catalog` (the model already carries every
  field this feature touches).

## 4. Design Overview

```
           ┌──────────────────────────────┐
⌘K / tap ──│  HierarchySidebarFeature     │── createSpace / selectSpace
           │  (popover)                   │
           │     "Manage Spaces…" ────────┼──► RootFeature.presentSpaceManager
           └──────────────────────────────┘
                                             │ sheet
                                             ▼
                              ┌──────────────────────────────┐
                              │ SpaceManagerFeature          │
                              │  — list / rename / reorder / │
                              │    delete                    │
                              │  — PendingSpaceRemoval       │
                              └──────────────┬───────────────┘
                                             │ HierarchyClient closures
                                             ▼
                              HierarchyManager (+ reorderSpace)
                                             │
                                             ▼
                                   catalog.json (debounced)
```

### 4.1 Data model — no changes

Everything the feature needs already exists on `Space` / `Catalog`:

- `Catalog.spaces: [Space]` — persisted order *is* display order.
- `Space.lastActiveWorktreeID` — wired via `setSpaceLastActiveWorktree`.
- `Catalog.selectedSpaceID` — drives restore-on-launch.

### 4.2 New manager method: `reorderSpace(from:to:)`

Added to `HierarchyManager` (existing file) and mirrored onto
`HierarchyClient` as the last closure in each signature list (append-only
per master's parallel-conflict rule). Implementation: pure
`catalog.spaces.move(fromOffsets:toOffset:)` + `store.scheduleSave`.

```swift
// HierarchyManager
func reorderSpaces(fromOffsets source: IndexSet, toOffset destination: Int) {
  guard !source.isEmpty else { return }
  catalog.spaces.move(fromOffsets: source, toOffset: destination)
  store.scheduleSave(catalog)
}
```

We use `IndexSet → offset` (SwiftUI's `.onMove` signature) rather than a
pair of `SpaceID`s so the reducer can forward the drop payload unchanged.
Silent no-op on empty `source`. Matches the dedup pattern used by
`setSpaceLastActiveWorktree`.

### 4.3 New `SpaceManagerFeature`

Location: `apps/mac/touch-code/App/Features/SpaceManager/`
(`SpaceManagerFeature.swift` + `SpaceManagerView.swift`).

#### State

```swift
@ObservableState
struct State: Equatable {
  var renameDraft: RenameDraft?                 // inline edit
  var pendingRemoval: PendingSpaceRemoval?      // confirmation
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
```

No copy of the Space list: the view reads `HierarchyManager.catalog.spaces`
from the environment, identical to how `HierarchySidebarView` reads
`.spaces[].projects`. Keeps a single source of truth and avoids mirror
bugs.

#### Actions

```swift
enum Action: Equatable {
  case renameRowTapped(SpaceID, currentName: String)
  case renameDraftChanged(String)
  case renameCommitted
  case renameCancelled

  case removeTapped(SpaceID, name: String)      // captures counts at tap-time
  case removeConfirmed
  case removeCancelled

  case reordered(IndexSet, Int)                 // .onMove payload

  case doneTapped                               // closes the sheet
}
```

#### Reducer behavior

- `renameCommitted`: trim, reject empty, forward to
  `hierarchyClient.renameSpace`, clear draft.
- `removeTapped`: computes counts from the snapshot at tap-time and
  parks them on `PendingSpaceRemoval` so the dialog text is stable even if
  catalog mutates underneath (same pattern as
  `PendingWorktreeRemoval.displayName`).
- `removeConfirmed`: forward to `hierarchyClient.removeSpace`. The
  existing `HierarchyManager.removeSpace` already falls back
  `selectedSpaceID` to `spaces.first?.id` — no extra logic needed.
- `reordered(from, to)`: forward to `hierarchyClient.reorderSpaces`.

**Last-Space guard:** The view disables the delete affordance when
`catalog.spaces.count == 1`. The reducer *also* short-circuits
`.removeConfirmed` on a single-Space catalog — belt-and-suspenders in case
a future keybinding or test path bypasses the UI disable.

#### View

A sheet with a single `List` using `.onMove` for drag-reorder. Each row:

```
┌─────────────────────────────────────────────────┐
│ ⋮⋮  Space name [TextField when editing]   ✏️ 🗑 │
└─────────────────────────────────────────────────┘
```

- Row tap → enter rename mode (focus a `TextField` bound to
  `state.renameDraft.text` when `renameDraft.spaceID == space.id`).
- Pencil button → same as row tap (explicit affordance for discoverability).
- Trash button → dispatches `.removeTapped`. Disabled when
  `spaces.count == 1`, tooltip: *"at least one Space must exist"*.
- Footer: "Done" button dismisses the sheet.

Inline duplicate-name hint: when the committed draft matches another
Space's name, show a `.font(.caption)` warning ("A Space with this name
already exists.") below the field but do not block the commit. Matches the
product spec's "non-blocking inline hint" Nice-to-Have.

### 4.4 Sheet hosting — `RootFeature.@Presents`

Following the existing `SettingsSheetFeature` pattern:

```swift
// RootFeature.State
@Presents var spaceManagerSheet: SpaceManagerFeature.State?

// RootFeature.Action
case spaceManagerSheetShown
case spaceManagerSheet(PresentationAction<SpaceManagerFeature.Action>)
```

New sidebar delegate case drives the presentation:

```swift
// HierarchySidebarFeature.Action.Delegate
case openSpaceManager
```

The popover's new "Manage Spaces…" button sends
`.delegate(.openSpaceManager)` *and* dismisses itself (`isSpacePopoverPresented = false`) — identical
pattern to the existing `openInDefaultEditor` delegate routing.

Rationale: the sheet is window-modal and its effects span features (edits
the catalog, closes terminal panes via cascade). Lifting it to
`RootFeature` matches where settings already lives and keeps the sidebar
reducer focused on sidebar concerns. TCA's `ifLet(\.$spaceManagerSheet,
…)` gives us automatic dismiss on child effect completion.

### 4.5 First-run default Space

Minimal change in `TouchCodeApp.init()`:

```swift
var catalog = (try? catalogStore.load()) ?? .default
if catalog.spaces.isEmpty {
  let seed = Space(name: "Personal")
  catalog.spaces = [seed]
  catalog.selectedSpaceID = seed.id
  // writeNow inside init would need await; scheduleSave runs when the
  // manager is constructed below.
}
let manager = HierarchyManager(catalog: catalog, store: catalogStore, …)
if needsSeedPersist { catalogStore.scheduleSave(manager.catalog) }
```

The manager's debounced save pipeline persists the seed on the usual
0.5 s timer — no need for a synchronous `saveNow`. If the user force-kills
the app in <500 ms the next launch reseeds, which is correct.

Alternative considered: seed inside `HierarchyManager.init` when
`catalog.spaces.isEmpty`. Rejected — the manager should not be opinionated
about fallback content; keep the policy in the app-bootstrap layer. Tests
that build a `HierarchyManager` directly (there are several) would also
have to special-case around an implicit seed.

### 4.6 Popover "Manage Spaces…" entry

Single new row under the existing `Divider()` in `spacePopover(catalog:)`:

```swift
Button {
  store.send(.spacePopoverManageSpacesTapped)
} label: { Label("Manage Spaces…", systemImage: "slider.horizontal.3") }
```

Reducer:

```swift
case .spacePopoverManageSpacesTapped:
  state.isSpacePopoverPresented = false
  return .send(.delegate(.openSpaceManager))
```

The existing popover layout is preserved; only one row is added. Does not
touch the Add Project (66–71) / Add Worktree (78–83) regions master
flagged.

### 4.7 Delete confirmation

`.confirmationDialog` attached to the SpaceManager sheet (not to Root), so
the parent sheet stays visible while the OS dialog is up.

- Title: `Remove Space "<name>"?`
- Message:
  *"This will remove <N> Project(s) and <M> Worktree(s) from touch-code.*
  *Files on disk are not affected."*
- Buttons: *Remove Space* (destructive) / *Cancel*.
- Counts (`N`, `M`) come from `PendingSpaceRemoval` captured at tap time.

If `catalog.spaces.count == 1` the reducer short-circuits and the UI
suppresses the trash button, so the dialog is never reached for the
last-Space case.

### 4.8 ⌘1–⌘9 (Nice-to-Have)

Extend `MainWindowCommands` with a private `@ViewBuilder` helper that
emits 9 buttons bound to `keyboardShortcut("1"…"9", modifiers: .command)`.
Each sends `.switchToSpaceAtIndex(Int)` into `RootFeature`, which resolves
the index against `hierarchyClient.snapshot().spaces` and forwards to
`.sidebar(.spaceRowTapped(id))` — reusing the same
`handleSpaceSwitch` choreography (outgoing `lastActiveWorktreeID` write,
incoming restore) that the popover uses.

Out-of-range indices are silent no-ops. Collisions with text-editing ⌘N
(select Nth suggestion in some menus) do not apply at window scope.

If any friction appears during implementation (e.g. conflict with an
existing menu binding), the ⌘1–⌘9 chunk is optional and will be dropped
from this PR.

## 5. Behavior Acceptance Matrix

Mapped 1:1 to the product spec's AC list:

| # | AC | Proof site |
|---|----|-----------|
| 1 | Fresh install seeds "Personal" | `TouchCodeApp.init` seed branch + new unit test on seed policy |
| 2 | Switcher updates sidebar within one frame, restores last Worktree | Existing `handleSpaceSwitch` + existing selection-stream plumbing |
| 3 | Round-trip A→B→A restores A's last Worktree | Existing wiring; covered by new reducer test exercising `handleSpaceSwitch` on a 2-Space catalog |
| 4 | Deleting only-Space: action disabled + tooltip | `SpaceManagerView` trash `.disabled`+`.help`; reducer guard |
| 5 | Cascade removes Projects/Worktrees in catalog, not on disk | Manager's `removeSpace` is pure data mutation — no filesystem touch. Test asserts temp-dir contents intact |
| 6 | Empty rename rejected | `renameCommitted` trim+empty guard; test asserts state rolls back |
| 7 | Reorder persists across restart | `reorderSpaces` writes through `scheduleSave`; integration test reloads a `CatalogStore` |

## 6. Alternatives Considered

- **Sheet vs. popover for the manager surface.** Spec Open Q prefers popover
  (consistent with T1). Rejected because drag-reorder inside a small
  popover is cramped and because the confirmation dialog needs stable
  parent chrome — a sheet handles both. "Manage Spaces…" *inside* the
  popover opens the sheet, so the popover-first entry point is
  preserved.
- **Manager state owned by `HierarchySidebarFeature`.** Rejected — the
  sheet is window-modal and its effects span beyond the sidebar (catalog
  mutation, terminal pane close). Matching `SettingsSheetFeature`'s
  Root-owned presentation keeps the two window-level sheets symmetric.
- **Eager persist on seed (saveNow).** Rejected — adds a throw path to
  `TouchCodeApp.init` for a 0.5 s window no user will notice; reseed on
  next launch is the safe default.
- **Model change: `Catalog.displayOrder: [SpaceID]`.** Rejected — the
  array itself is already ordered and every existing writer respects
  array order (`.append`, `.remove(at:)`, …). Adding a parallel order
  array would create a second source of truth for zero benefit.

## 7. Testing Strategy

- **`HierarchyManagerTests`** (new in `TouchCodeCoreTests` or
  `touch-code/Tests` — match existing placement of manager tests):
  `reorderSpaces_movesElementsAndSchedulesSave`, `reorderSpaces_emptyIndexSet_isNoOp`.
- **`SpaceManagerFeatureTests`** (new): rename trim/empty, remove tapped
  captures counts from snapshot, remove confirmed forwards to client,
  remove on single-Space catalog is short-circuited, reorder forwards
  the move payload.
- **`HierarchySidebarFeatureTests`** (extend): `manageSpacesTapped`
  dismisses popover and emits `.delegate(.openSpaceManager)`.
- **`RootFeatureTests`** (extend): sidebar delegate `.openSpaceManager`
  sets `state.spaceManagerSheet != nil`; dismiss nils it.
- **First-run seed** (new, likely in `TouchCodeCoreTests` alongside
  `CatalogCodableTests`): loading an empty catalog + running the seed
  branch produces a catalog with a single "Personal" Space selected.
- **Manual**: create 3 Spaces, rename one inline, drag-reorder, delete
  one, quit, relaunch, verify order + active Space persisted.

## 8. Rollout / Risks

- All changes are additive. No migration needed; existing catalogs load
  unchanged. Single-Space catalogs opened in the new build acquire a
  disabled trash affordance but no behavior change.
- `reorderSpaces` is a new client closure — appended to the end of
  `HierarchyClient`'s property list *and* of its `live` / `liveValue` /
  `testValue` init lists per master's parallel-conflict rule. T-PROJECT
  and T-WORKTREE children must re-sync after any of the three PRs merge;
  diff-lines are small and append-only.
- Risk: ⌘K popover + sheet interaction. SwiftUI allows a sheet to be
  presented while a popover is dismissed in the same tick; we verify by
  hand-running `⌘K → Manage Spaces…` during manual QA.

## 9. Open Questions (resolved by master)

- S-Q1 (popover entry) — **a (popover → sheet)**.
- S-Q2 (delete confirmation shows counts) — **yes**.
- S-Q3 (first-run name) — **"Personal"**.

No new open questions.
