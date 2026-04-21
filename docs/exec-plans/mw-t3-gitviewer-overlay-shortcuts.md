# ExecPlan: Main-Window T3 — Git Viewer Overlay & Keyboard Shortcuts

**Status:** Draft
**Author:** Gump (T3 sub-agent, via Claude)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a touch-code user can:

- Toggle the Git Viewer on or off per Worktree — the state persists across relaunches and follows the user from Worktree to Worktree, no longer a single global flag.
- See the Git Viewer render as a right-edge overlay on top of the terminal region while the Tab bar and Worktree header remain fully clickable above it.
- Press **⌘E** to open the current Worktree in its resolved default editor (per-Project override → global default → Finder) without reaching for the Header dropdown.
- Press **⌘⇧G** to toggle the Git Viewer overlay for the current Worktree.
- Press **⌘K** to open the Sidebar Space-switcher popover (lands as a minimal `spaceSwitcherOpenToken` contract T1 observes; rebase collapses to a direct sidebar action if T1 exposes one).

T2 (Header) will reuse the same toggle action for its GV button, so the Header button, ⌘⇧G, and any future API caller all go through a single reducer entry point.

## Progress

- [x] M0 — Rebase onto origin/feature/main-window (tip 61bfeef; T1/T2 not yet merged); three conditionals all ABSENT → add path (2026-04-21)
- [x] M1 — RootFeature: derived `gitViewerOverlayVisible` + `.gitViewerToggledForCurrentWorktree` + `.openSpaceSwitcherRequested`; remove `inspectorVisible`; HierarchyClient `setWorktreeGitViewerVisible` added (2026-04-21; touch-code tests green)
- [x] M2 + M3 — WorktreeDetailView overlay host + `MainWindowConstants` + width-clamp helper; ContentView 2-col simplification (2026-04-21; shared commit per plan; tests green)
- [x] M4 — EditorFeature `.openDefaultInCurrentWorktreeRequested` + new static `resolveDefaultEditorID` helper (T2 absent at this round; reuse path deferred) (2026-04-21)
- [x] M5 — MainWindowCommands + attach to WindowGroup; ⌘K dispatches `.openSpaceSwitcherRequested` (token path per D1b-round1) (2026-04-21)
- [x] M6 — Tests: RootFeature (projection, toggle, token, no-selection guard), EditorFeature (openDefault × 3 branches + pure resolver), WorktreeDetailView width clamp — 480 tests green (2026-04-21)
- [x] M7 REV1 — Rebase onto ee3f088 (T1+T2 merged); three conditionals re-checked per D1a/b/c-round2; D8 sidebar follow-up shipped; lint + TouchCodeCore + touch-code + tcKit green; force-push + PR_READY (REV1) (2026-04-21)
- [x] M7 REV2 — BLOCKER fix per D9: drop cached `gitViewerOverlayVisible`, replace with live-catalog helper so Header-button write path and ⌘⇧G reducer path share one source of truth. NIT 1 (docs refer to `MainWindowConstants`) + NIT 2 (EditorFeature override tests split into installed + uninstalled cases). lint + TouchCodeCore + touch-code + tcKit green; force-push + PR_READY (REV2) (2026-04-21)

## Surprises & Discoveries

- **M0 ghostty prebuild** (2026-04-21): `make -C apps/mac generate` failed at the Ghostty remote tarball fetch (400 Bad Request), same as T0 M1's note. Worked around by copying the entire `/Users/wanggang/dev/00/touch-code/apps/mac/.build/ghostty/` directory into `apps/mac/.build/ghostty/`. Fingerprint short-circuits the build-ghostty.sh step on re-generate.
- **M0 baseline lint fails** (2026-04-21): `make -C apps/mac lint` reports two pre-existing violations before any T3 edit — `apps/mac/touch-code/Tests/Hooks/HookDispatcherPerfTests.swift:45` (async_without_await; blame `e04de710` 2026-04-21) and `apps/mac/tcKit/SkillRunners.swift:174` (function_body_length 113>100; blame `ac16d24c` 2026-04-20). Same shape as T0 M7 precedent; escalated via CLARIFY to master before starting M1.

## Decision Log

- **D1** (planning, 2026-04-21): `gitViewerOverlayVisible` is a **derived projection** computed in the reducer on every `.selectionChanged`, not a free Bool on `RootFeature.State`. Reason: it's fully a function of `(state.selection, catalog)`; a free Bool invites drift and breaks "single source of truth = catalog".
- **D2** (planning, 2026-04-21): `.gitViewerToggledForCurrentWorktree` performs an **optimistic local flip** of the derived projection before firing the `HierarchyClient` setter. Reason: avoids a visible one-frame lag between Header click / ⌘⇧G press and overlay appearance. Next `.selectionChanged` reconciles from the persisted catalog.
- **D3** (planning, 2026-04-21): ⌘K uses a monotonic **`spaceSwitcherOpenToken: UInt`** counter on `RootFeature.State`. Repeated presses bump the counter so T1's `.onChange(of:)` fires even when the popover was dismissed between keypresses. If T1 (post-rebase) exposes a direct `.sidebar(.openSpacePopover)` action, ⌘K swaps to that and the token field is removed (per master coordination note 3).
- **D4** (planning, 2026-04-21, per master coordination note 2): `HierarchyClient.setWorktreeGitViewerVisible` is a **conditional add** — if T2's merged PR already added this closure, T3 reuses it and skips the add in M1. Otherwise T3 adds it next to `setDefaultEditor`.
- **D5** (planning, 2026-04-21, per master coordination note 4): ⌘E resolution (per-Project override → global default → Finder) lives in a **single static helper**. If T2 has merged a `resolveDefault` helper (likely on `EditorFeature` or a neighbouring type), `.openDefaultInCurrentWorktreeRequested` calls it; otherwise T3 introduces the helper alongside the new action. The two entry points (Header button, ⌘E) **do not** fan-out through different resolution paths.
- **D6** (planning, 2026-04-21): Keyboard shortcuts ship via a SwiftUI `Commands` block (`CommandGroup(after: .newItem)`) rather than hidden `.keyboardShortcut(...)` buttons. Reason: menu-bar discoverability + window-scope binding survive first-responder changes better than on-screen hidden buttons.
- **D1a-round1** (execute M0, 2026-04-21): `HierarchyClient.setWorktreeGitViewerVisible` ABSENT → T3 adds the closure per M1. T1/T2 not yet merged; re-check after each future rebase.
- **D1b-round1** (execute M0, 2026-04-21): T1 sidebar popover action ABSENT (T1 still in Plan per master) → T3 adds `spaceSwitcherOpenToken` + `.openSpaceSwitcherRequested` per M1. Re-check after each future rebase.
- **D1c-round1** (execute M0, 2026-04-21): T2 `resolveDefault` helper ABSENT (T2 just entered Execute per master) → T3 introduces `resolveDefaultEditorID` static helper on `EditorFeature` per M4. Re-check after each future rebase.
- **D1a-round2** (post-rebase REV1 onto ee3f088, 2026-04-21): T2 landed `HierarchyClient.setWorktreeGitViewerVisible` — **PRESENT**. Kept T2's declaration + doc-comment; removed my duplicate during rebase. Live binding / liveValue / testValue entries auto-merged cleanly.
- **D1b-round2** (post-rebase REV1 onto ee3f088, 2026-04-21): T1 did **not** expose an open-only sidebar popover action (sidebar uses `spaceFooterTapped` toggle). Token path stands: `spaceSwitcherOpenToken` + `.openSpaceSwitcherRequested` retained. T1 sidebar view will need to add `.onChange(of:)` to observe the token when wiring ⌘K — called out in PR.
- **D1c-round2** (post-rebase REV1 onto ee3f088, 2026-04-21): T2 landed `EditorFeature.resolveDefault(projectOverride:globalDefault:descriptors:) -> ResolvedDefault` + `EditorFeature.finderEditorID` — **PRESENT**. Removed my local `resolveDefaultEditorID`. `.openDefaultInCurrentWorktreeRequested` now reads the per-Project override from the catalog, calls `resolveDefault`, and maps `.editor`/`.finder` to the `EditorID` that `.openRequested` expects. EditorFeatureTests kept T2's pure-helper suite and replaced my helper test with three TestStore forwarding cases on the new shape.
- **D8** (rebase REV1 follow-up, 2026-04-21): Replaced the inline override → global → Finder resolution inside `.sidebar(.delegate(.openInDefaultEditor))` with a call to `EditorFeature.resolveDefault` + `projectOverrideEditorID(for:)`. Semantic delta: the sidebar no longer filters on `isInstalled` — the shared helper accepts any descriptor in the cache, and the downstream `.openRequested` surfaces `.notInstalled` via the editor toast. Rationale: unify all three entry points (Header dropdown, sidebar context menu, ⌘E) on one resolver; a visible failure beats silent fall-through to Finder.
- **D9** (REV2 BLOCKER fix per master, 2026-04-21): Drop the cached `RootFeature.State.gitViewerOverlayVisible` Bool; replace with `State.gitViewerOverlayVisible(in: Catalog) -> Bool` that views call with the observed `hierarchyManager.catalog`. Supersedes D1 + D2. Reason: T2's `WorktreeHeaderFeature.gitViewerToggled` writes `gitViewerVisible` directly through `hierarchyClient.setWorktreeGitViewerVisible` without going through `.gitViewerToggledForCurrentWorktree`, so a cached projection diverges from the catalog between a Header click and the next `.selectionChanged`. Modelling the visibility as a live read against the catalog makes SwiftUI `@Observable` tracking the sync mechanism — both toggle entry points write the catalog, and both the view and the reducer read it the same way. `.gitViewerToggledForCurrentWorktree` simplifies to "read catalog snapshot → setter with flipped value"; `.selectionChanged` no longer refreshes a projection. Matches the pattern T2 REV1 used for the bell's unread count.

## Outcomes & Retrospective

**2026-04-21 — M0 through M6 shipped on `feat/mw-gitviewer-shortcuts`; M7 push + PR pending.**

Shipped:
- Lint suppression unblocks T3 on the rebased baseline (matches T0 M7 precedent).
- RootFeature: per-Worktree `gitViewerOverlayVisible` derived projection; `.gitViewerToggledForCurrentWorktree` optimistic toggle + persist; `.openSpaceSwitcherRequested` bumps a monotonic token T1 can observe.
- HierarchyClient: new `setWorktreeGitViewerVisible` closure forwarding to `HierarchyManager.setWorktreeGitViewerVisible`.
- WorktreeDetailView: terminal-region overlay hosts `GitViewerView` at a fixed 360-pt width with a 480-pt min-terminal clamp; pure `shouldShowOverlay(totalWidth:)` helper; suppressed-width hint badge.
- ContentView: simplified to a two-column NavigationSplitView; old inspector toolbar + HStack third column removed.
- EditorFeature: `.openDefaultInCurrentWorktreeRequested` + shared static `resolveDefaultEditorID` (override → globalDefault → Finder) feeding the existing `.openRequested` pipeline.
- MainWindowCommands: ⌘E / ⌘⇧G / ⌘K attached to WindowGroup.
- Tests: four new RootFeature cases, four new EditorFeature cases, two-case WorktreeDetailView layout suite; 480 tests green via `xcodebuild test -scheme touch-code`; `TouchCodeCore` + `tcKit` also green.

Gaps / deferred:
- T1/T2 not yet merged; D1a/D1b/D1c re-check scheduled for every future rebase. After T2 merges the expectation is to drop the local `HierarchyClient.setWorktreeGitViewerVisible` closure and reuse T2's. After T1 merges, if a direct popover action lands, ⌘K swaps to it and the token field goes.
- `WorktreeHeaderOpenButton` still carries its own private override→globalDefault→Finder resolution inline; when a shared helper becomes clearly useful to a second caller (beyond ⌘E), consolidate onto `EditorFeature.resolveDefaultEditorID`. Not in scope to rewrite the header right now.

Lessons:
- `EditorClient.open`'s signature is `(URL, EditorID?, ProjectID?) -> EditorChoice`; writing a typed test stub caught the optional-EditorID contract that wasn't obvious from usage sites.
- Pure static helper (`resolveDefaultEditorID`) + exhaustivity-off TestStore + exact-action `store.receive(...)` turned out to be the cleanest way to cover a multi-branch forwarding reducer without duplicating fixture scaffolding.
- `buildableFolders` in Tuist recurses into new sub-directories automatically — creating `App/Commands/` required no Project.swift edit.

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/ui-main-window-redesign.md` (§Should-Have for the three shortcuts, §Must-Have "Git Viewer toggle" + per-Worktree persistence).
- Design doc: `docs/design-docs/mw-t3-gitviewer-overlay-shortcuts.md` — read in full before touching code; it contains the API surface diagrams, alternatives considered, and the component-boundary table.
- T0 foundation (dependency): `docs/design-docs/mw-t0-foundation.md` — specifies `Worktree.gitViewerVisible` and `HierarchyManager.setWorktreeGitViewerVisible` contracts T3 consumes.
- Architecture doc: `docs/architecture.md`.
- Golden rules: `docs/golden-rules.md`.

Key source files:

- `apps/mac/touch-code/App/ContentView.swift` — hosts the outer `NavigationSplitView`. Today renders GitViewer as an `HStack` third column and owns the `inspectorVisible` toolbar button; M3 strips both.
- `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift` — renders the Worktree header strip, Tab bar, and terminal region (SplitViewport / emptyTab). M2 attaches the overlay to the terminal region only.
- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — the reducer that will gain two actions (`.gitViewerToggledForCurrentWorktree`, `.openSpaceSwitcherRequested`) and one derived state field (`gitViewerOverlayVisible`), and lose `inspectorVisible` / `.inspectorVisibilityToggled`.
- `apps/mac/touch-code/App/Features/Editor/EditorFeature.swift` — gains `.openDefaultInCurrentWorktreeRequested` forwarding to `.openRequested`. Resolution helper reused from T2 if present (see D5).
- `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift` — reference implementation for the default-editor label resolution chain; M4 extracts this logic or reuses T2's extraction.
- `apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerView.swift` + `GitViewerKeybindings.swift` — untouched. The overlay hosts `GitViewerView` verbatim; in-view j/k/g/G handlers gate on `press.modifiers.isEmpty` and do not collide with the new ⌘-modified commands.
- `apps/mac/touch-code/App/Clients/HierarchyClient.swift` — may need one new `@Sendable` closure (`setWorktreeGitViewerVisible`) if T2's rebase did not already add it.
- `apps/mac/touch-code/Runtime/HierarchyManager.swift` lines 213+ — live `setWorktreeGitViewerVisible(worktreeID:visible:)` already shipped by T0 M2. Not modified.
- `apps/mac/touch-code/App/TouchCodeApp.swift` — the `WindowGroup { ContentView(...) }` scene. M5 attaches `.commands { MainWindowCommands(store: ...) }`.

Test targets:

- `apps/mac/touch-code/Tests/RootFeatureTests.swift` — extend with projection, toggle, token-bump, and no-selection-guard tests.
- `apps/mac/touch-code/Tests/EditorFeatureTests.swift` — extend with openDefault override/global/Finder branches.
- `apps/mac/touch-code/Tests/WorktreeDetailViewLayoutTests.swift` **(new file)** — pure logic test for the width-clamp helper. Keeps layout assertions out of SwiftUI preview scaffolding.

Terms of art:

- **Overlay host**: the view (`WorktreeDetailView`'s terminal region) that attaches `.overlay(alignment: .trailing) { GitViewerView }`. The overlay is a SwiftUI *view modifier*, not a child column; the host view's own layout is unaffected by the overlay's presence.
- **Width-clamp**: the rule that suppresses overlay rendering when `geometry.size.width < MainWindowConstants.gvOverlayMinTerminalWidth + MainWindowConstants.gvOverlayWidth`. State stays `true`; only rendering is skipped. Reappears when the window widens.
- **Derived projection**: a field on `RootFeature.State` recomputed from other state + the catalog snapshot on specific trigger actions, rather than set independently. Views read it like any other state; reducer owns its lifecycle.
- **Space-switcher open token**: a `UInt` counter on `RootFeature.State` that the reducer increments on ⌘K. The Sidebar view observes `onChange(of: token)` and opens a popover; token value is meaningless beyond "changed".

Orientation: the work splits cleanly along the TCA edges. M1 owns all reducer-level changes and the one client closure. M2 + M3 own the view layer. M4 owns the editor-feature action. M5 owns the new Commands block + its attachment to the WindowGroup. M6 is tests. M0 (rebase + conditional decisions) and M7 (verification + PR) bookend the work. **Do not proceed past M0 without recording the three conditional decisions in the Decision Log** — they determine whether M1/M4/M5 add or reuse code.

### Post-rebase conditional decision matrix (filled at M0)

| Conditional | Check (post-rebase) | If present → | If absent → |
|---|---|---|---|
| `HierarchyClient.setWorktreeGitViewerVisible` closure | `grep -n "setWorktreeGitViewerVisible" apps/mac/touch-code/App/Clients/HierarchyClient.swift` | M1 skips the closure add; reuses T2's | M1 adds the closure next to `setDefaultEditor` |
| T1 direct sidebar popover action (`.sidebar(.openSpacePopover)` or equivalent) | `grep -rn "openSpacePopover\|openSpaceSwitcher\b" apps/mac/touch-code/App/Features/HierarchySidebar/` | M5 binds ⌘K to the direct action; M1 omits `spaceSwitcherOpenToken` + `.openSpaceSwitcherRequested` | M1 adds `spaceSwitcherOpenToken` + `.openSpaceSwitcherRequested`; M5 dispatches the root action |
| T2 `resolveDefault` static helper for (override → global → Finder) resolution | `grep -rn "resolveDefault\|defaultEditorID(for:" apps/mac/touch-code/App/Features/` | M4's new action calls the existing helper | M4 introduces a private `static func resolveDefaultEditorID(...)` on `EditorFeature` with the same resolution chain as `WorktreeHeaderOpenButton.currentDefaultLabel` |

Each row's outcome is recorded in the Decision Log during M0 before any code edit begins.

## Plan of Work

### Milestone 0 — Rebase and record conditional decisions

Goal: the branch is up-to-date with `origin/feature/main-window` (T1 + T2 merged), the test + lint baselines are green on the rebased tip, and the three conditional decisions from the matrix above are recorded in the Decision Log before any T3 code lands.

Fetch and rebase:

    cd /Users/wanggang/.worktree/repos/touch-code/feat/mw-gitviewer-shortcuts
    git fetch origin
    git rebase origin/feature/main-window

Resolve any conflicts. Expected conflict hotspots (`ContentView.swift`, `RootFeature.swift`) are exactly the files T3 will rewrite in M1/M3 — prefer the incoming (T1/T2) side during rebase, since T3 re-expresses its own changes after rebase.

Run the three `grep` checks from the matrix; record outcomes as D1a/D1b/D1c in the Decision Log. Run baseline lint + test to confirm the rebased tree is green before introducing new changes:

    make -C apps/mac lint
    cd apps/mac && xcodebuild test -scheme TouchCodeCoreTests -destination 'platform=macOS' | tail -20
    cd apps/mac && xcodebuild test -scheme touch-code -destination 'platform=macOS' | tail -20
    cd apps/mac && xcodebuild test -scheme touch-codeTests -destination 'platform=macOS' | tail -20

Expected: all green. If a pre-existing failure appears (as happened in T0 M7 with `async_without_await`), escalate via `CLARIFY` before starting M1. No commit at M0.

### Milestone 1 — RootFeature reducer changes + HierarchyClient (conditional)

Goal: after M1, the reducer owns `gitViewerOverlayVisible` (derived), two new actions (`.gitViewerToggledForCurrentWorktree`, `.openSpaceSwitcherRequested` — the second conditional on D1b), and the old `inspectorVisible` surface is gone. The client closure for writing `gitViewerVisible` is either reused from T2 or added.

In `apps/mac/touch-code/App/Features/Root/RootFeature.swift`:

- Remove `var inspectorVisible: Bool = false` from `State`.
- Remove `case inspectorVisibilityToggled` from `Action` and its reducer branch.
- Add `var gitViewerOverlayVisible: Bool = false` to `State` with a doc-comment: *"Derived projection of `(state.selection, catalog.worktree.gitViewerVisible)`. Writes go through `.gitViewerToggledForCurrentWorktree`; `.selectionChanged` reconciles. Views read directly; no one should assign to this field outside the reducer."*
- If D1b says "add token path" (T1 has no direct action):
  - Add `var spaceSwitcherOpenToken: UInt = 0` to `State` with a doc-comment naming T1 as the observer.
  - Add `case openSpaceSwitcherRequested` to `Action`; reducer branch does `state.spaceSwitcherOpenToken &+= 1; return .none`.
- If D1b says "direct action available": skip the token field and the root action; M5 dispatches T1's sidebar action directly.
- Add `case gitViewerToggledForCurrentWorktree` to `Action`. Reducer branch:
  - Guard `let worktreeID = state.selection.worktreeID` → `.none` if absent.
  - Compute `target = !state.gitViewerOverlayVisible`, optimistically assign.
  - Return a fire-and-forget effect that calls `hierarchyClient.setWorktreeGitViewerVisible(worktreeID, target)` on the main actor.
- Modify the existing `.selectionChanged(_)` branch: after assigning `state.selection = selection`, call a new private helper `resolveOverlayVisibility(_:)` that reads `hierarchyClient.snapshot()` and walks to the worktree; assign the result to `state.gitViewerOverlayVisible`. Do this **before** the existing `.send(.gitViewer(.worktreeSelected(...)))`.

In `apps/mac/touch-code/App/Clients/HierarchyClient.swift`:

- If D1a says "absent": add `var setWorktreeGitViewerVisible: @MainActor @Sendable (WorktreeID, Bool) -> Void` to the struct next to `setDefaultEditor`. Wire live binding in `live(manager:)` → `{ manager.setWorktreeGitViewerVisible(worktreeID: $0, visible: $1) }`. Wire `testValue` → `unimplemented` stub (or a `@Sendable _ in {}` no-op, matching the style of neighbouring test bindings).
- If D1a says "present": reuse as-is; no edit.

In `apps/mac/touch-code/App/ContentView.swift`:

- Remove the `ToolbarItem` that sends `.inspectorVisibilityToggled`.
- (The `HStack` 3-column GitViewer render stays for now — it's ripped out in M3 after M2 provides the new overlay host; keeps M1's compile step clean.)

Acceptance: the reducer compiles; `xcodebuild test -scheme touch-code` runs the existing tests (old `inspectorVisibilityToggled` tests, if any, must be updated or removed as part of this milestone). No behavior change visible to the user yet — the old HStack rendering still shows GitViewer. The reducer-level plumbing is ready for M2/M3 to hang the new UI off.

**Commit after M1**: `refactor(root): per-worktree gitViewerOverlayVisible + replace inspectorVisible toggle`

### Milestone 2 — WorktreeDetailView overlay host + width-clamp constants

Goal: the new overlay rendering site exists inside `WorktreeDetailView`, gated by an `overlayVisible: Bool` parameter and by a width-clamp helper. Not yet wired into ContentView — M3 does that.

In `apps/mac/touch-code/App/Theme/MainWindowConstants.swift` (create if absent):

```swift
enum Constants {
  static let gvOverlayWidth: CGFloat = 360
  static let gvOverlayMinTerminalWidth: CGFloat = 480
}
```

If `MainWindowConstants.swift` already exists, add the two properties to the existing enum without reshuffling.

In `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift`:

- Add two new parameters: `gitViewerStore: StoreOf<GitViewerFeature>` and `overlayVisible: Bool`.
- Extract the existing `if let tabID = address.activeTab { SplitViewportView(...) } else { emptyTab }` block into a private `@ViewBuilder` method `terminalRegion(address:)` so the overlay attaches to exactly that subtree.
- Attach `.overlay(alignment: .trailing) { overlayContent(...) }` to `terminalRegion`, where `overlayContent` uses a `GeometryReader` to compute whether the overlay should render or show a suppressed hint, per the design doc §API Design §6.
- Add a pure helper (file-private or nested) `static func shouldShowOverlay(totalWidth: CGFloat) -> Bool { totalWidth >= MainWindowConstants.gvOverlayMinTerminalWidth + MainWindowConstants.gvOverlayWidth }`. The helper is the unit-test target in M6.
- The suppressed-hint variant is a small static badge: *"Widen window to show Git Viewer"* in `.caption.foregroundStyle(.secondary)` inside a `.background(.thinMaterial, in: .capsule)` padding; placed near the trailing edge so the user sees it without covering terminal content. Not animated.

The Worktree header strip and `TabBarView` remain outside the overlay host; do not move them.

Acceptance: the file compiles; no call sites yet (ContentView still passes the old parameter list — that's OK because Swift will emit an "extra argument" error at the *ContentView* site, caught in M3). To avoid an intermediate broken commit, do not land M2 alone — combine with M3 in one commit, or keep M2 uncommitted until M3 is ready. Plan: combine M2 + M3 into one commit.

### Milestone 3 — ContentView simplification + overlay wiring

Goal: `ContentView` becomes a clean two-column `NavigationSplitView`; GitViewer is rendered only via the new overlay inside `WorktreeDetailView`.

In `apps/mac/touch-code/App/ContentView.swift`:

- Replace the `HStack { WorktreeDetailView(...); if store.inspectorVisible { Divider; GitViewerView(...) } }` detail column with a single `WorktreeDetailView(...)` call, passing the two new parameters (`gitViewerStore: store.scope(state: \.gitViewer, action: \.gitViewer)`, `overlayVisible: store.gitViewerOverlayVisible`).
- The `editorToastOverlay` `.overlay(alignment: .bottom)` stays where it is, wrapping the new detail column.
- The settings button in `.toolbar` stays. (The old inspector toolbar button was already removed in M1.)
- Delete the dead comment block referring to `InspectorPlaceholder`.

Manual verification during execution (not an automated test):

- Launch the app.
- Toggle the overlay via the existing Header button (T2 renders it) — overlay slides in from the right.
- Switch Worktree A (overlay visible) → Worktree B (overlay hidden) → back. State follows Worktree.
- Relaunch the app; last overlay state is restored per Worktree.
- Narrow the window until terminal width < 480pt — overlay disappears, hint appears. Widen — overlay returns.

Acceptance: `xcodebuild build -scheme touch-code` succeeds. Manual walkthrough above passes.

**Commit after M2+M3**: `feat(ui): render GitViewer as right-edge overlay with per-worktree visibility`

### Milestone 4 — EditorFeature `.openDefaultInCurrentWorktreeRequested`

Goal: one action handles the `⌘E` path, resolving the default editor through the same chain as `WorktreeHeaderOpenButton.currentDefaultLabel`.

In `apps/mac/touch-code/App/Features/Editor/EditorFeature.swift`:

- Add to `Action`:

  ```swift
  case openDefaultInCurrentWorktreeRequested(
    spaceID: SpaceID,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    worktreePath: String
  )
  ```

- Add a reducer branch that:
  - Reads the project override via `hierarchyClient.snapshot()` (or `HierarchyClient.catalog()` if named differently post-rebase).
  - Calls the resolution helper to pick the editor ID: override → `state.globalDefault` → Finder ID (the constant used by the built-in "Finder" editor descriptor; grep `EditorID.*finder` during M0 to confirm the constant name).
  - Returns `.send(.openRequested(editorID: resolved, worktreePath: worktreePath, projectID: projectID))`.

- Resolution helper (per D5):
  - **If D1c says "reuse":** import / call T2's existing helper. Do not duplicate.
  - **If D1c says "introduce":** add `private static func resolveDefaultEditorID(projectID: ProjectID, spaceID: SpaceID, catalog: Catalog, globalDefault: EditorID?) -> EditorID` with the exact chain used by `WorktreeHeaderOpenButton.currentDefaultLabel`: `catalog.spaces[...].projects[...].defaultEditor` → `globalDefault` → Finder ID.
  - Add a doc-comment on the helper stating it is the shared resolution rule and lists its two callers (header button + ⌘E).

Acceptance: `xcodebuild test -scheme touch-code` green after the M6 tests land. Manual: press ⌘E with an active Worktree — the default editor opens (no toast of type `.failed` unless the editor is missing).

**Commit after M4**: `feat(editor): add openDefaultInCurrentWorktree action for shortcut binding`

### Milestone 5 — MainWindowCommands + attach to WindowGroup

Goal: the three keyboard shortcuts fire and dispatch real actions.

Create `apps/mac/touch-code/App/Commands/MainWindowCommands.swift`:

```swift
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

struct MainWindowCommands: Commands {
  let store: StoreOf<RootFeature>
  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open in Default Editor") { sendOpenDefault() }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!hasActiveWorktree)

      Button("Toggle Git Viewer") {
        store.send(.gitViewerToggledForCurrentWorktree)
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      .disabled(!hasActiveWorktree)

      Button("Switch Space…") {
        // D1b decides which action fires here — edit at M0
        store.send(.openSpaceSwitcherRequested)
      }
      .keyboardShortcut("k", modifiers: .command)
    }
  }

  private var hasActiveWorktree: Bool { store.state.selection.worktreeID != nil }

  private func sendOpenDefault() {
    guard
      let spaceID = store.state.selection.spaceID,
      let projectID = store.state.selection.projectID,
      let worktreeID = store.state.selection.worktreeID
    else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let path = catalog.spaces.first(where: { $0.id == spaceID })?
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?.path
    else { return }
    store.send(.editor(.openDefaultInCurrentWorktreeRequested(
      spaceID: spaceID,
      projectID: projectID,
      worktreeID: worktreeID,
      worktreePath: path
    )))
  }
}
```

Note: `@Dependency` inside a `Commands` struct is legal — the swift-composable-architecture dependency system resolves on first access on the main actor.

In `apps/mac/touch-code/App/TouchCodeApp.swift`:

- Attach `.commands { if let store = appState.store { MainWindowCommands(store: store) } }` to the `WindowGroup`. Place after `.windowStyle(.titleBar)`.

If D1b is "direct action": replace the `⌘K` button's `store.send(.openSpaceSwitcherRequested)` line with the exact sidebar action T1 exposed, and delete references to `spaceSwitcherOpenToken` / `.openSpaceSwitcherRequested` introduced in M1.

Acceptance: app launches; the File menu shows the three entries with the shortcut hints; pressing each one in the running app performs the described action.

**Commit after M5**: `feat(app): add ⌘E ⌘⇧G ⌘K main-window keyboard shortcuts`

### Milestone 6 — Tests

Goal: reducer + editor + layout-clamp tests cover every new action and every branch of the default-editor resolver.

In `apps/mac/touch-code/Tests/RootFeatureTests.swift`:

- `selectionChangedRefreshesGitViewerOverlayVisible` — inject a test `hierarchyClient` whose `snapshot()` returns a scripted catalog with Worktree A (`gitViewerVisible = true`) and B (`false`). Send `.selectionChanged(...)` for A → expect `state.gitViewerOverlayVisible == true`. Send for B → expect `false`.
- `gitViewerToggleUpdatesStateAndCallsHierarchyClient` — arrange selection on Worktree A (`gitViewerVisible = false` initially). Use a recording `setWorktreeGitViewerVisible` closure. Send `.gitViewerToggledForCurrentWorktree`. Expect `state.gitViewerOverlayVisible == true` and the recorded call was `(A.id, true)`.
- `gitViewerToggleWithoutSelectionIsNoOp` — selection with nil worktreeID; send toggle; expect no state change and zero recorded calls.
- If D1b is "token path": `openSpaceSwitcherRequestedBumpsToken` — send twice; expect `state.spaceSwitcherOpenToken == 2`.

In `apps/mac/touch-code/Tests/EditorFeatureTests.swift`:

- `openDefaultInCurrentWorktreeWithProjectOverrideForwardsOverride` — catalog with per-Project override `vscode`, globalDefault `zed`. Expect follow-up `.openRequested(editorID: vscode, ...)`.
- `openDefaultInCurrentWorktreeFallsBackToGlobalDefault` — no override, globalDefault `zed`. Expect `.openRequested(editorID: zed, ...)`.
- `openDefaultInCurrentWorktreeFallsBackToFinder` — no override, no globalDefault. Expect `.openRequested(editorID: <finder constant>, ...)`.

Create `apps/mac/touch-code/Tests/WorktreeDetailViewLayoutTests.swift`:

- `overlayShowsAboveThreshold` — `shouldShowOverlay(totalWidth: 480+360)` → `true`; `shouldShowOverlay(totalWidth: 480+360+1)` → `true`.
- `overlayHiddenBelowThreshold` — `shouldShowOverlay(totalWidth: 480+360-1)` → `false`; `shouldShowOverlay(totalWidth: 479)` → `false`.

Acceptance: all three test schemes (`TouchCodeCoreTests`, `touch-code`, `touch-codeTests`) pass.

**Commit after M6**: `test(t3): cover overlay projection, toggle, openDefault resolution, width clamp`

### Milestone 7 — Lint, full verification, push, PR

Goal: the branch is green on the rebased tip, pushed to origin, and a PR is open targeting `feature/main-window`.

Run, in order (from the repo root):

    make -C apps/mac lint
    cd apps/mac && xcodebuild test -scheme TouchCodeCoreTests -destination 'platform=macOS' | tail -30
    cd apps/mac && xcodebuild test -scheme touch-code -destination 'platform=macOS' | tail -30
    cd apps/mac && xcodebuild test -scheme touch-codeTests -destination 'platform=macOS' | tail -30

All four must be green. Any failure → fix and re-run; do not push red.

Push and open PR:

    git push -u origin feat/mw-gitviewer-shortcuts
    gh pr create --base feature/main-window --title "T3: git viewer overlay & main-window shortcuts" --body-file - <<'EOF'
    ## Summary
    - Git Viewer renders as a right-edge overlay inside `WorktreeDetailView`; Tab bar + Worktree header stay above and clickable
    - Overlay visibility is per-Worktree, sourced from `Worktree.gitViewerVisible` (T0 contract)
    - New shortcuts: ⌘E (open in default editor), ⌘⇧G (toggle overlay), ⌘K (open Space switcher)
    - Removed `RootFeature.State.inspectorVisible` and the toolbar button that drove it

    ## T0 contract consumption
    - Reads and writes `Worktree.gitViewerVisible` via `HierarchyManager.setWorktreeGitViewerVisible`

    ## Cross-task coordination
    - T2 Header GV button dispatches the shared `.gitViewerToggledForCurrentWorktree` (no direct state writes)
    - T1 Sidebar observes `RootFeature.State.spaceSwitcherOpenToken` via `.onChange(of:)` to open its Space-switcher popover — OR, if post-rebase T1 exposed a direct action, ⌘K dispatches that action and the token is removed

    ## Test plan
    - [ ] Toggle overlay via Header button; state persists across relaunch
    - [ ] Switch between Worktrees with different `gitViewerVisible` values; overlay state follows Worktree
    - [ ] ⌘E opens the resolved default editor (override → global → Finder)
    - [ ] ⌘⇧G toggles the overlay
    - [ ] ⌘K opens the Space switcher popover
    - [ ] Narrow window below terminal < 480pt → overlay suppressed with hint; widen → overlay returns
    - [ ] GitViewer internal j/k/g/G keybindings still work when the overlay has focus

    🤖 Generated with [Claude Code](https://claude.com/claude-code)
    EOF

Then push `PR_READY: <url>` to master.

## Concrete Steps

The exact commands above, in milestone order, are the concrete steps. Re-state here for copy-paste convenience:

**M0:**

    cd /Users/wanggang/.worktree/repos/touch-code/feat/mw-gitviewer-shortcuts
    git fetch origin
    git rebase origin/feature/main-window
    grep -n "setWorktreeGitViewerVisible" apps/mac/touch-code/App/Clients/HierarchyClient.swift || echo "ABSENT"
    grep -rn "openSpacePopover\|openSpaceSwitcher\b" apps/mac/touch-code/App/Features/HierarchySidebar/ || echo "ABSENT"
    grep -rn "resolveDefault\|defaultEditorID(for:" apps/mac/touch-code/App/Features/ || echo "ABSENT"

Record each outcome as `D1a` / `D1b` / `D1c` under Decision Log.

**M1 → M7:** each commits once; see individual acceptance sections.

**Verification at M7 (expected tail):**

    Test Suite 'All tests' passed at ...
          Executed NNN tests, with 0 failures ... seconds

## Validation and Acceptance

End-to-end, the PR ships when these five behaviors verify by hand (script this as a quick run before pushing PR_READY):

1. **Header toggle persists**: click the T2 Header GV button → overlay appears; quit + relaunch → overlay state restored.
2. **Per-Worktree state**: arrange Worktree A visible, B hidden. Click back and forth. Overlay follows.
3. **⌘E opens default editor**: an active Worktree is selected; `⌘E` opens in the resolved default editor with no manual selection.
4. **⌘⇧G toggles**: `⌘⇧G` flips the overlay visibility. Press again; flips back. Exactly mirrors the Header button.
5. **⌘K opens switcher**: `⌘K` opens the T1 Space-switcher popover. (If T1 did not merge a direct action and the ⌘K path uses the token, verify T1's `.onChange(of:)` hookup still reacts.)

And these four automated checks are green on the rebased tip:

- `make -C apps/mac lint`
- `xcodebuild test -scheme TouchCodeCoreTests`
- `xcodebuild test -scheme touch-code`
- `xcodebuild test -scheme touch-codeTests`

## Idempotence and Recovery

- M0 rebase is idempotent: re-running `git fetch origin && git rebase origin/feature/main-window` on an already-rebased branch is a no-op.
- M1–M6 each end with an independently-passing test suite and a single commit. If a later milestone breaks, `git revert <commit>` rolls back to a known-good state; no intermediate state is persisted to disk.
- The `Worktree.gitViewerVisible` field is always safe to read: T0 guarantees the decode default is `false`, so a user who downgrades to a pre-T3 binary (still post-T0) loses only the UI hook; the catalog stays valid.
- `spaceSwitcherOpenToken` wraps on `UInt` overflow (`&+=`). Any integer value is a valid "changed" signal for T1's `.onChange(of:)`.
- Recovery from a failed M7 push: rebase again (origin may have moved), re-run verification, re-push. Do **not** force-push — open a second PR or wait for the master to merge the earlier state.

## Artifacts and Notes

Reference implementations to study before implementation:

- `apps/mac/touch-code/App/Features/WorktreeHeader/WorktreeHeaderOpenButton.swift` lines 106-124 — the `currentDefaultLabel` / `projectOverrideID` resolution chain; M4 mirrors exactly.
- `apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerKeybindings.swift` — demonstrates the `press.modifiers.isEmpty` guard that keeps internal keys from conflicting with our new ⌘-modified commands.
- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` `.selectionChanged` branch — the pattern T3 extends; add the projection refresh here, not in a separate action.
- `apps/mac/touch-code/Runtime/HierarchyManager.swift` lines 213–226 — the T0-shipped setter M1's reducer calls via the client.
- `apps/mac/touch-code/App/TouchCodeApp.swift` — the only `WindowGroup` site; `Commands` attaches here.

## Interfaces and Dependencies

At the end of M1, `apps/mac/touch-code/App/Features/Root/RootFeature.swift` must define (within `RootFeature`):

    extension RootFeature.State {
      var gitViewerOverlayVisible: Bool      // derived; written only by reducer
      var spaceSwitcherOpenToken: UInt       // conditional on D1b
    }

    extension RootFeature.Action {
      case gitViewerToggledForCurrentWorktree
      case openSpaceSwitcherRequested        // conditional on D1b
    }

And `RootFeature.State` must no longer contain `inspectorVisible`; `RootFeature.Action` must no longer contain `inspectorVisibilityToggled`.

At the end of M1 (conditional on D1a), `apps/mac/touch-code/App/Clients/HierarchyClient.swift` must define:

    nonisolated struct HierarchyClient: Sendable {
      // ... existing closures
      var setWorktreeGitViewerVisible: @MainActor @Sendable (WorktreeID, Bool) -> Void
    }

Live binding forwards to `hierarchyManager.setWorktreeGitViewerVisible(worktreeID:visible:)`.

At the end of M4, `apps/mac/touch-code/App/Features/Editor/EditorFeature.swift` must define (within `EditorFeature`):

    extension EditorFeature.Action {
      case openDefaultInCurrentWorktreeRequested(
        spaceID: SpaceID,
        projectID: ProjectID,
        worktreeID: WorktreeID,
        worktreePath: String
      )
    }

And a resolver with the shape (conditional on D1c — either new or reused):

    static func resolveDefaultEditorID(
      projectID: ProjectID,
      spaceID: SpaceID,
      catalog: Catalog,
      globalDefault: EditorID?
    ) -> EditorID

At the end of M2, `apps/mac/touch-code/App/Theme/MainWindowConstants.swift` must define:

    enum Constants {
      static let gvOverlayWidth: CGFloat = 360
      static let gvOverlayMinTerminalWidth: CGFloat = 480
    }

At the end of M2, `WorktreeDetailView` must accept:

    struct WorktreeDetailView: View {
      let store: StoreOf<WorktreeDetailFeature>
      let selection: HierarchySelection
      let editorStore: StoreOf<EditorFeature>
      let gitViewerStore: StoreOf<GitViewerFeature>   // NEW
      let overlayVisible: Bool                        // NEW
      // body as in design doc §6
    }

At the end of M5, `apps/mac/touch-code/App/Commands/MainWindowCommands.swift` must define:

    struct MainWindowCommands: Commands { ... }

And `TouchCodeApp.swift`'s `WindowGroup` scene must attach `.commands { if let store = appState.store { MainWindowCommands(store: store) } }`.
