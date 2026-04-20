# ExecPlan: TCA Shell (0007)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, running `make mac-run-app` opens a touch-code window that looks like a terminal orchestrator rather than a single-shell demo:

- A two-column `NavigationSplitView` — sidebar on the left, active-Worktree detail on the right.
- The sidebar lists every Space, expands into Projects, and each Project expands into Worktrees. Clicking a Worktree makes it the active context.
- The active Worktree shows a horizontal tab bar. Clicking "New Tab" adds a Tab and makes it active; clicking a Tab swaps the detail pane to that Tab's `SplitTree<PanelID>`.
- Each Tab's viewport renders one or more live libghostty Panels, recursively laid out from `SplitTree`. "Split right" / "Split down" commands add a new Panel inside the active Tab; closing the last Panel leaves an empty Tab placeholder.
- Quitting and relaunching restores every level — sidebar selection, active Tab, and split geometry — via the shipped `CatalogStore`.
- Creating a Worktree / Tab / Panel and removing them is driven through `HierarchyClient` and `TerminalClient` `DependencyKey` bridges. Every future feature (C6 inbox sidebar, C7 git viewer, C8 editor settings) composes into `RootFeature` and reuses these clients without touching runtime state directly.

This is the composition layer that unlocks downstream capability work. C6 / C7 / C8 don't ship here; they get a `RootFeature` to inject into and a place in the view hierarchy to live.

## Progress

- [x] M1 — Add TCA dependency + `HierarchyClient` and `TerminalClient` `DependencyKey`s with `liveValue` / `testValue` wired into the shipped `HierarchyManager` and `TerminalEngine` — 2026-04-20
- [ ] M2 — `RootFeature` scaffold + `ContentView` with an empty `NavigationSplitView`; `TouchCodeApp` mounts `ContentView` in place of `MainView`; event-stream subscription armed
- [ ] M3 — `HierarchySidebarFeature` + `HierarchySidebarView` with Space → Project → Worktree navigation driven by `HierarchyClient`
- [ ] M4 — `WorktreeDetailFeature` composing `TabBarFeature` and `SplitViewportFeature`; detail column renders active Tab's `SplitTree<PanelID>` via `PanelHostView`
- [ ] M5 — Lazy surface lifecycle: switching Tab / Worktree calls `ensureSurface` for the incoming Tab's leaves and `closeSurface` for the outgoing Tab's leaves
- [ ] M6 — Presentation plumbing: sheets for "New Space", "Add Project", "New Worktree", "New Tab"; alerts for destructive confirmations; empty-Tab placeholder view

## Surprises & Discoveries

(None yet)

## Decision Log

- **DEC-0 (planning, 2026-04-20): nit fix on `selectProject` / `selectWorktree` signatures.** Original draft used two `_ in:` parameter labels in a row, which does not compile. Renamed to `inSpace` / `inProject` at signature level; keeps call sites readable (`hierarchyClient.selectWorktree(id, inProject: p, inSpace: s)`).
- **DEC-1 (M1 gate, 2026-04-20): `selectionChanges()` added to `HierarchyClient` in M1.** Downstream C7 `GitViewerFeature` and C6 inbox both need to react to Worktree selection changes. Without a stream on the client, features would need to hold a `HierarchyManager` reference and observe `@Observable` directly — leaking the single-writer concern into TCA reducers. The stream samples on `TerminalEvent.hierarchyMutated(.selection | .space | .project | .worktree)` and dedupes. M4 `WorktreeDetailFeature` also consumes it to swap the detail column on worktree change. **Must ship in M1** so M3+ features build against a stable surface.
- **DEC-2 (M3 gate, 2026-04-20 — deferred to M3 kickoff): C6 Inbox placement.** C6 M5 ships a sidebar-class feature (~320 pt secondary column). Two options: (a) three-column `NavigationSplitView` with inbox as a permanent secondary column, or (b) root-level mode toggle that swaps `HierarchySidebarView` ↔ `InboxSidebarView` in the leading column. *Leaning:* option (b). Rationale: three-column navigation is visually heavy for a single-window tool whose primary task is the detail pane; toggling on demand keeps the sidebar footprint small and mirrors how mail apps present inbox vs. folders. A `mode: SidebarMode { case hierarchy; case inbox }` state on `RootFeature` drives the swap; the existing `HierarchySidebarFeature` is untouched. Re-confirm at M3 kickoff before freezing the sidebar's view topology.
- **DEC-3 (M4 gate, 2026-04-20 — deferred to M4 kickoff): `SplitViewportFeature.State` needs `activeTabID: TabID?`.** M4 must seed this as part of state so M5's `.tabActivated` transition has a field to update. Documented here so M4 doesn't ship "empty state" and M5 doesn't have to retrofit.
- **DEC-4 (M6 gate, 2026-04-20 — deferred to M6 kickoff): C8 Settings presentation slot.** M6 adds `@Presents var settingsSheet: SettingsFeature.State?` to `RootFeature.State` as a commented placeholder. C8 plan will define `SettingsFeature`; today's M6 reserves the slot so C8 can drop in without reshaping root state. One-line `// @Presents var settingsSheet: … // reserved for C8` comment is enough.

## Outcomes & Retrospective

### M1 — TCA dep + clients (2026-04-20)

**What landed:**
- `apps/mac/Tuist/Package.swift` — `swift-composable-architecture` pinned at `1.23.1`; Tuist fetched swift-custom-dump, swift-navigation, swift-sharing, swift-dependencies transitively.
- `apps/mac/Project.swift` — `.external(name: "ComposableArchitecture")` added to the `touch-code` app target.
- `apps/mac/touch-code/App/Clients/HierarchyClient.swift` — 18 commands + `snapshot` + `selectionChanges` stream. Per DEC-1, `selectionChanges` uses `withObservationTracking` to sample `manager.catalog.selectedSpaceID/Project/Worktree` on every mutation, deduped against the prior snapshot. `HierarchyClient.live(manager:)` static factory for app startup; `liveValue` + `testValue` `DependencyKey` conformance with `unimplemented` placeholders.
- `apps/mac/touch-code/App/Clients/TerminalClient.swift` — 6 commands (sendInput, setFocus, retryPanel, ensureSurface, closeSurface, events). `ensureSurface` throws `TerminalClient.Error.worktreeNotFound` when the address doesn't resolve inside the current catalog.
- `apps/mac/touch-code/Runtime/HierarchyManager.swift` — added `selectSpace`, `selectProject(in:)`, `selectWorktree(in:in:)`, `selectTab(in:in:in:)` backing mutations the client wraps.
- `apps/mac/touch-code/Tests/HierarchyClientTests.swift` (4 tests) + `TerminalClientTests.swift` (2 tests).

**Verification:** `make mac-build` → `BUILD SUCCEEDED`. `make mac-lint` → clean. `xcodebuild test -scheme touch-code` → **39 tests in 7 suites passed** (33 prior + 6 new client tests). No user-visible change — app still launches via `MainView`'s `SingleSurfaceHost`.

**Carry-forward to M2:** `RootFeature.onLaunch` will subscribe to `terminalClient.events()` and `hierarchyClient.selectionChanges()` concurrently. `ContentView` will use `.withDependencies { $0.hierarchyClient = .live(manager:); $0.terminalClient = .live(engine:) }` at store construction.

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capabilities C1 and C2 are already shipped; this plan stands up the TCA shell that C6/C7/C8 will plug into.
- Design doc — [docs/design-docs/0007-tca-shell.md](../design-docs/0007-tca-shell.md) — **authoritative** for every design decision (state ownership, client split, feature topology).
- Previous ExecPlan — [docs/exec-plans/0002-terminal-and-hierarchy.md](0002-terminal-and-hierarchy.md) — shipped `HierarchyManager`, `TerminalEngine`, `CatalogStore`, `GhosttyRuntime`, `PanelSurface`, `PanelHostView`. This plan composes them; it does not modify the shipped primitives.
- Architecture — [docs/architecture.md](../architecture.md), especially `§ State Management` (hybrid TCA + `@Observable`) and the `touch-code/App` module boundary.
- Golden rules — [docs/golden-rules.md](../golden-rules.md)

Reference projects (filesystem-local, read-only — borrow first, deviate with stated reason):

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - `supacode/App/ContentView.swift` — canonical `NavigationSplitView` host with `@Bindable var store: StoreOf<AppFeature>` and `terminalManager: WorktreeTerminalManager` passed separately. This is exactly the pattern our `ContentView` adopts.
  - `supacode/Features/App/Reducer/AppFeature.swift` — root reducer composing sub-features with `Scope`; `@Dependency` injection; `enum Action` with `case terminalEvent(TerminalClient.Event)`.
  - `supacode/Clients/Terminal/TerminalClient.swift` — `DependencyKey` + `liveValue` + `testValue` pattern we replicate for both clients.
  - `supacode/Features/Repositories/Views/SidebarView.swift` — sidebar list view pattern with `store.send(…)` row actions.
- **supaterm** — `/Users/wanggang/dev/opensource/supaterm`
  - `apps/mac/supaterm/Features/Terminal/TerminalWindowFeature.swift` — `@Reducer` + `@ObservableState` layout with presentation state, modal editor state, and a `CancelID` enum for the event subscription effect.

Source files this plan touches (all under `apps/mac/touch-code/`):

- `App/TouchCodeApp.swift` — `@main` entry; currently mounts `MainView()`; M2 replaces the body content with `ContentView` wrapping a `StoreOf<RootFeature>`.
- `App/MainView.swift` — shipped single-surface demo; superseded by `ContentView`. Kept for the `#Preview { … }` usage in M2, deleted in M6 once the shell is self-sufficient.
- `App/PanelHostView.swift` — shipped `NSViewRepresentable` over `PanelSurface`. Unchanged; M4 consumes it from `SplitViewportView`.
- `Runtime/HierarchyManager.swift`, `Runtime/TerminalEngine.swift`, `Runtime/Ghostty/*` — shipped. Read-only from this plan's perspective.
- `App/Clients/HierarchyClient.swift`, `App/Clients/TerminalClient.swift` — new in M1.
- `App/Features/Root/RootFeature.swift`, `App/ContentView.swift` — new in M2.
- `App/Features/HierarchySidebar/{HierarchySidebarFeature,HierarchySidebarView}.swift` — new in M3.
- `App/Features/WorktreeDetail/{WorktreeDetailFeature,WorktreeDetailView}.swift`, `App/Features/TabBar/{TabBarFeature,TabBarView}.swift`, `App/Features/SplitViewport/{SplitViewportFeature,SplitViewportView}.swift` — new in M4.
- `Tuist/Package.swift` — M1 adds `swift-composable-architecture`.
- `Project.swift` — M1 extends the `touch-code` target's `dependencies:` with `.external(name: "ComposableArchitecture")`.

**Terminology used in this plan** (define once, use everywhere):

- **DependencyKey** — a Point-Free Dependencies API type with `liveValue`, `testValue`, optionally `previewValue`. Injected into TCA reducers via `@Dependency(\.keyPath)`. `HierarchyClient` and `TerminalClient` conform.
- **Scope** — TCA's mechanism to route a sub-state/sub-action pair from a parent reducer to a child reducer. `RootFeature.body` uses `Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }`.
- **@ObservableState** — TCA macro that makes feature state participate in SwiftUI observation (no `viewStore` wrapper needed; views read `store.state` directly).
- **snapshot** — `HierarchyClient.snapshot() -> Catalog` returns an immutable value-type copy. Useful in TestStores and as an `Equatable` payload for features that need the tree in their state. The live UI does not use this — it reads `HierarchyManager.catalog` through `@Environment` at render time.
- **Lazy surface creation** — a `PanelSurface` is created (via `TerminalEngine.ensureSurface`) only when its containing Tab becomes visible. Switching away does not destroy it in v1; that happens on explicit panel close. Addresses NFR: idle CPU ≈ 0%.

**Orientation paragraph.** Six milestones slice the shell vertically. M1 drops in TCA and the two client bridges — nothing user-visible, but the foundation every subsequent feature builds on. M2 lights up a two-column empty shell so the window frame reflects the new topology immediately. M3 brings the sidebar online, so Spaces / Projects / Worktrees can be navigated. M4 fills the detail column with a functional tab bar and split viewport, hooked up to the shipped `PanelHostView`. M5 adds the lazy lifecycle so switching between Worktrees with many Tabs stays snappy. M6 wires creation/removal modals and the empty-Tab placeholder so every mutation has a UI entry point. After M6, C6 / C7 / C8 can land without further shell changes.

## Plan of Work

### Milestone 1: TCA dependency + client bridges

**Goal after this milestone.** `ComposableArchitecture` is on SPM; `HierarchyClient.liveValue` and `TerminalClient.liveValue` forward commands to the shipped `HierarchyManager` and `TerminalEngine`; `testValue` uses unimplemented closures for TDD; a trivial test feature confirms `@Dependency` injection works end-to-end. Nothing user-visible changes — the app still launches with `MainView` and the single hardcoded shell.

**Work.** Add `.package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1")` to `apps/mac/Tuist/Package.swift` (matching supacode and supaterm). In `apps/mac/Project.swift`, add `.external(name: "ComposableArchitecture")` to the `touch-code` target's `dependencies:`. `make mac-generate` picks up both changes.

Create `apps/mac/touch-code/App/Clients/HierarchyClient.swift`. Define a `HierarchyClient` struct of `@MainActor @Sendable` closures, one per command from the design doc's API surface (`createSpace`, `renameSpace`, `removeSpace`, `addProject`, `removeProject`, `createWorktree`, `removeWorktree`, `selectSpace`, `selectProject`, `selectWorktree`, `createTab`, `closeTab`, `selectTab`, `openPanel`, `splitPanel`, `closePanel`, `focusPanel`, `resizeSplit`, plus a `snapshot` read). Because `HierarchyManager`'s APIs are already `@MainActor`, each `liveValue` closure is a one-line call into the manager. `testValue` uses `XCTestDynamicOverlay.unimplemented` so unexercised closures trap. Expose `DependencyValues.hierarchyClient`.

Also expose `selectionChanges() -> AsyncStream<HierarchySelection>` — a coarse stream that emits whenever the `selectedSpaceID → selectedProjectID → selectedWorktreeID` chain changes in the catalog. The `liveValue` implementation is a thin wrapper around `HierarchyManager`'s existing `@Observable` accessors: an `AsyncStream` continuation that samples on every `.hierarchyMutated(.selection)` / `.hierarchyMutated(.space(_))` / `.hierarchyMutated(.project(_, _))` / `.hierarchyMutated(.worktree(_, _, _))` event from the engine stream and dedupes against the previous snapshot. Required by C7 `GitViewerFeature` (worktree-scope changes drive diff refresh) and C6 inbox (per-worktree filtering); adding it here keeps TCA reducers feature-pure — they never hold a `HierarchyManager` reference.

Create `apps/mac/touch-code/App/Clients/TerminalClient.swift` with a parallel structure: `sendInput`, `setFocus`, `retryPanel`, `ensureSurface(panelID, spaceID, projectID, worktreeID, tabID)`, `closeSurface(panelID)`, and `events() -> AsyncStream<TerminalEvent>`. `liveValue` wraps `TerminalEngine`; note that `ensureSurface` needs the full hierarchy address because `HierarchyManager.findWorktree` is private — the live implementation looks the worktree up via `hierarchyManager.catalog` and throws `TerminalClient.Error.worktreeNotFound` if missing.

Add `apps/mac/touch-code/Tests/HierarchyClientTests.swift` and `TerminalClientTests.swift`: each instantiates a TCA `TestStore` using a trivial throwaway reducer that exposes one `@Dependency` closure and verifies the injected `testValue` override traps / the `liveValue` with a real `HierarchyManager` produces the expected catalog mutation. Two tests per file is enough — the clients are thin forwarders.

**Observable acceptance.** `make mac-generate && make mac-build` produces `BUILD SUCCEEDED`. `xcodebuild test -scheme touch-code` → 35 tests pass (existing 33 + 2 client tests). `make mac-lint` is clean. App binary still launches `MainView` with the single shell (no regression).

**Expected commits.** Two commits: `chore(tuist): add TCA dependency (TCA Shell M1)` and `feat(app): HierarchyClient + TerminalClient DependencyKeys (TCA Shell M1)`.

### Milestone 2: RootFeature + empty NavigationSplitView + TouchCodeApp swap

**Goal after this milestone.** `TouchCodeApp` mounts a `StoreOf<RootFeature>`-backed `ContentView` that renders an empty two-column `NavigationSplitView`. `RootFeature` subscribes to `terminalClient.events()` on launch and cancels the effect on quit. The old `MainView` is not yet removed — it's still compiled but unreachable. No hierarchy data is visible yet; the sidebar is a placeholder "No Space selected" and the detail column shows a blank `EmptyView`.

**Work.** Create `apps/mac/touch-code/App/Features/Root/RootFeature.swift`:

    @Reducer
    struct RootFeature {
      @ObservableState
      struct State: Equatable {
        var sidebar = HierarchySidebarFeature.State()     // added in M3
        var detail  = WorktreeDetailFeature.State()       // added in M4
      }
      enum Action: Equatable {
        case onLaunch
        case engineEvent(TerminalEvent)
        case sidebar(HierarchySidebarFeature.Action)      // routed in M3
        case detail(WorktreeDetailFeature.Action)         // routed in M4
      }
      @Dependency(\.terminalClient) var terminalClient
      // body composes sub-features via Scope; M3 / M4 fill in.
    }

M2 leaves the sub-feature cases + `Scope` calls commented out — the root body only handles `.onLaunch` (subscribes to events via `Effect.run(priority: .background) { send in for await event in terminalClient.events() { await send(.engineEvent(event)) } }` with `CancelID.events`) and `.engineEvent` (no-op routing until features exist).

Create `apps/mac/touch-code/App/ContentView.swift`:

    struct ContentView: View {
      @Bindable var store: StoreOf<RootFeature>
      let hierarchyManager: HierarchyManager
      let terminalEngine: TerminalEngine
      @State private var columnVisibility: NavigationSplitViewVisibility = .all

      var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          Text("Sidebar placeholder")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
          Text("Select a Worktree")
        }
        .environment(hierarchyManager)
        .environment(terminalEngine)
        .task { store.send(.onLaunch) }
      }
    }

Update `apps/mac/touch-code/App/TouchCodeApp.swift`. The `@main` struct gains a once-initialised `HierarchyManager` + `TerminalEngine` + `CatalogStore` + `GhosttyRuntime` stack (formerly inside `SingleSurfaceHost`), constructs the root `Store`, and passes both the store and the managers into `ContentView`. Use `.init(initialState:reducer:withDependencies:)` to override `.hierarchyClient` / `.terminalClient` with `liveValue` variants bound to the actual manager/engine instances — the built-in `liveValue` is too early-bound for this pattern.

`MainView` is **not deleted** in M2. Keep the file; remove it in M6 once `ContentView` is fully featured so the in-flight milestone always has a fallback.

Add `apps/mac/touch-code/Tests/RootFeatureTests.swift` with two tests: `onLaunchArmsEventSubscription` (uses a `TestStore` with `terminalClient.events` yielding a single fake `.panelReady` then finishing, asserts the `.engineEvent` action is received) and `onLaunchCancelsOnFinish` (asserts no leak after the stream ends).

**Observable acceptance.** `make mac-run-app` opens the window, shows an empty two-column layout. The sidebar column is a text placeholder; the detail column says "Select a Worktree". No segfault; no libghostty surface yet. Tests: 37 passing. Quitting cancels the event-subscription effect cleanly (no hang).

**Expected commits.** Two commits: `feat(app): RootFeature scaffold with event stream subscription (TCA Shell M2)` and `feat(app): ContentView with empty NavigationSplitView (TCA Shell M2)`.

### Milestone 3: HierarchySidebarFeature + sidebar navigation

**Goal after this milestone.** The sidebar shows every Space, every Project under each Space, every Worktree under each Project. Clicking a Worktree persists that selection via `HierarchyClient.selectWorktree`; the catalog update lands in `HierarchyManager` and triggers a debounced save. The detail column still says "Select a Worktree" — M4 gives it the tab bar + viewport.

**Work.** Create `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`:

    @Reducer
    struct HierarchySidebarFeature {
      @ObservableState
      struct State: Equatable {
        var expandedSpaceIDs: Set<SpaceID> = []
        var expandedProjectIDs: Set<ProjectID> = []
      }
      enum Action: Equatable {
        case spaceRowTapped(SpaceID)
        case projectRowTapped(ProjectID)
        case worktreeRowTapped(WorktreeID, projectID: ProjectID, spaceID: SpaceID)
        case toggleSpaceExpansion(SpaceID)
        case toggleProjectExpansion(ProjectID)
      }
      @Dependency(\.hierarchyClient) var hierarchyClient
    }

Row-tap actions call the matching `hierarchyClient.select*` command and update local expansion sets. Toggle actions only mutate local expansion state.

Create `apps/mac/touch-code/App/Features/HierarchySidebar/HierarchySidebarView.swift`. The view signature is:

    struct HierarchySidebarView: View {
      @Bindable var store: StoreOf<HierarchySidebarFeature>
      @Environment(HierarchyManager.self) private var hierarchyManager
      var body: some View { … }
    }

The view reads `hierarchyManager.catalog.spaces` directly — this is the core pattern from the design doc. Render as nested `DisclosureGroup`s inside a `List`:

    List {
      ForEach(hierarchyManager.catalog.spaces) { space in
        DisclosureGroup(isExpanded: Binding(…)) {
          ForEach(space.projects) { project in
            DisclosureGroup(isExpanded: Binding(…)) {
              ForEach(project.worktrees) { worktree in
                WorktreeRow(worktree: worktree, isSelected: …) {
                  store.send(.worktreeRowTapped(worktree.id, projectID: project.id, spaceID: space.id))
                }
              }
            } label: { ProjectRow(project: project, …) }
          }
        } label: { SpaceRow(space: space, …) }
      }
    }

Filter `expandedSpaceIDs` and `expandedProjectIDs` against the current catalog on every render (design doc R2: stale IDs).

Mount the sidebar in `ContentView`: replace the placeholder `Text` with `HierarchySidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))`. Add `Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }` to `RootFeature.body`.

Add `apps/mac/touch-code/Tests/HierarchySidebarFeatureTests.swift` with 3 tests: `worktreeRowTappedCallsSelectWorktree` (TestStore with stubbed `hierarchyClient.selectWorktree` closure that records its argument), `toggleSpaceExpansionFlipsExpandedSet`, `expandedSetsPruneStaleIDsOnCatalogChange`.

**Observable acceptance.** Seed a catalog via a throwaway debug hook (or `prowl send` into the app's shell: `tc space create test`; but `tc` isn't live yet — see M6 for the real seed path, or just use `hierarchyClient.createSpace` from a `.task { }` closure in a dev build flag). Launch: sidebar shows the seeded Space → Project → Worktree tree. Click a Worktree row; `~/.config/touch-code/catalog.json` updates its `selectedWorktreeID` within 500 ms (debounced). Tests: 40 passing.

**Expected commits.** Two commits: `feat(app): HierarchySidebarFeature + tests (TCA Shell M3)` and `feat(app): HierarchySidebarView — Space/Project/Worktree tree (TCA Shell M3)`.

### Milestone 4: WorktreeDetailFeature + TabBar + SplitViewport + PanelHostView wiring

**Goal after this milestone.** Selecting a Worktree fills the detail column with a horizontal tab bar on top and a split viewport below. Clicking "New Tab" creates a Tab; clicking a Tab button swaps the viewport; "New Panel" inside a Tab creates a Panel and renders a live libghostty shell via the shipped `PanelHostView`. Splitting horizontally / vertically adds a second pane. Closing the last Panel leaves an empty viewport placeholder — the Tab persists.

**Work.** Create three features under `apps/mac/touch-code/App/Features/`:

1. `WorktreeDetail/WorktreeDetailFeature.swift` — composes `TabBarFeature` + `SplitViewportFeature` via `Scope`. State holds placeholders; actions route. No logic of its own beyond composition.
2. `TabBar/TabBarFeature.swift` — actions: `newTabButtonTapped`, `tabButtonTapped(TabID)`, `closeButtonTapped(TabID)`. Each dispatches to `hierarchyClient.createTab / selectTab / closeTab` using the current selection read from the snapshot. Reducer returns no-op `.none` effects; state is empty (TabBar is a thin controller over the catalog).
3. `SplitViewport/SplitViewportFeature.swift` — actions: `newPanelButtonTapped(atPanelID: PanelID?, direction: SplitTree<PanelID>.NewDirection)`, `closePanelButtonTapped(PanelID)`, `focusPanelRequested(PanelID)`, `resizeSplitRequested(path: SplitTree<PanelID>.Path, ratio: Double)`. Each forwards to `hierarchyClient.*` + `terminalClient.ensureSurface` / `closeSurface`.

Create matching views under the same directories. `TabBarView` is a horizontal `ScrollView` of `Button`s + a `+` button. `SplitViewportView` is recursive over `SplitTree.Node`:

    func renderNode(_ node: SplitTree<PanelID>.Node, tab: Tab) -> some View {
      switch node {
      case .leaf(let panelID):
        panelView(for: panelID, in: tab)
      case .split(let split):
        splitBody(split: split, tab: tab)
      }
    }

`panelView(for:)` resolves the live `PanelSurface` via `terminalEngine.surface(for: panelID)` (shipped API). If the surface exists, return `PanelHostView(surface: surface)`; otherwise return an `EmptyView` — M5 is responsible for creating surfaces on tab activation.

`splitBody` uses an `HSplitView` or `VSplitView` (AppKit-backed `NSSplitView` via a thin `NSViewRepresentable`) with two children. Wrap the split ratio in a `Binding` that sends `resizeSplitRequested` on change.

Mount into `ContentView` by replacing the detail placeholder `Text` with:

    WorktreeDetailView(
      store: store.scope(state: \.detail, action: \.detail),
      selection: hierarchyManager.activeSelection
    )

`activeSelection` is a small helper on `HierarchyManager` (add to shipped code if it doesn't already exist) that returns `(spaceID, projectID, worktreeID, tabID)?` reading from the catalog's `selectedSpaceID → …` chain. Detail renders `EmptyView` when `activeSelection == nil`.

Add tests for each sub-feature — three per feature is enough: one for the happy path, one for the failing-call path (client throws / returns nil), and one for state invariants.

**Observable acceptance.** Seed a Space → Project → Worktree → Tab with no panels. Click the Worktree: detail column shows an empty tab bar + a "new tab" button. Click "New Panel" inside a Tab: a live shell appears. Split right: a second pane appears horizontally. Type in each independently. Close the right pane: back to one pane. Close the last pane: detail shows "No panels in this tab; New Panel". Tests: 49 passing.

**Expected commits.** Three commits: `feat(app): WorktreeDetailFeature composition (TCA Shell M4)`, `feat(app): TabBarFeature + TabBarView (TCA Shell M4)`, `feat(app): SplitViewportFeature + recursive SplitViewportView (TCA Shell M4)`.

### Milestone 5: Lazy surface lifecycle

**Goal after this milestone.** Switching to a Worktree with five Tabs spins up surfaces only for the active Tab's Panels, not for the other four Tabs. Switching Tabs inside the Worktree is a single-frame operation: the previous Tab's surfaces are frozen (not destroyed); the incoming Tab's surfaces are created if missing. Closing a Panel immediately destroys its surface. Idle CPU with ten Tabs and one visible Panel must be ≈ 0%.

**Work.** In `SplitViewportFeature.reducer` (or a small coordinator reducer layer above it — to be decided at implementation time), react to `.detail(.tabActivated(TabID))` by iterating the incoming Tab's panels and calling `terminalClient.ensureSurface` for each. React to `.engineEvent(.tabActivated(TabID))` (the same event, source of truth) for symmetric handling when the catalog flips selection from a non-UI path.

Do **not** destroy outgoing-Tab surfaces on deactivation. Product spec NFR "Tab switch < 16ms" would suffer from reopening surfaces; keep them alive until explicit close. Memory cost is bounded (NFR: <50 MB per idle Panel; typical active session ≤ 20 Panels).

Make `TerminalEngine.ensureSurface` robust to re-entry: the shipped implementation already checks for an existing surface and returns it. M5 tests exercise that path.

Add `apps/mac/touch-code/Tests/SplitViewportLazyLifecycleTests.swift`: seed a Tab with two Panels; simulate `.tabActivated`; assert `ensureSurface` was called twice (once per Panel, via a recording `TerminalClient.testValue`). Tab deactivation test: assert `closeSurface` was **not** called.

Update `RootFeature.handleEvent(event:)` to route `.tabActivated` into the detail feature.

**Observable acceptance.** Launch with a seeded catalog containing one Worktree, five Tabs, two Panels per Tab (all persisted from a prior session). Only two libghostty surfaces are alive at launch (the active Tab's panels). `Activity Monitor` shows ~0% CPU at idle. Switching Tabs spawns the incoming surfaces within one frame (visible in a frame capture). Tests: 52 passing.

**Expected commits.** Two commits: `feat(app): lazy surface creation on tab activation (TCA Shell M5)` and `test(app): lifecycle regression tests (TCA Shell M5)`.

### Milestone 6: Creation modals + empty-Tab placeholder + MainView cleanup

**Goal after this milestone.** Every mutation has a GUI entry point. Clicking "New Space" in the sidebar root opens a sheet with a name field. "Add Project" opens a folder picker + name field. "New Worktree" opens a sheet with branch name, path (defaulted to `<repo-root>-worktrees/<branch>`), and an "also run `git worktree add`" toggle. Destructive operations (remove Space / Project / Worktree / Tab) prompt with an `@Presents` alert. Empty-Tab state shows a centered "New Panel" button. `MainView` + `SingleSurfaceHost` are deleted.

**Work.** Add `@Presents` children to the relevant feature states:

    @ObservableState struct State: Equatable {
      @Presents var newSpaceSheet: NewSpaceFeature.State?
      @Presents var addProjectSheet: AddProjectFeature.State?
      @Presents var newWorktreeSheet: NewWorktreeFeature.State?
      @Presents var confirmRemoveAlert: AlertState<ConfirmRemoveAction>?
    }

Each new sub-feature is small: a draft-name field + a confirm action that sends `hierarchyClient.createX` and dismisses. `AddProjectFeature` uses the `FileImporter` modifier + `GitWorktreeCLI.discoverGitRoot` (shipped) to auto-detect whether the picked folder is a git repo. `NewWorktreeFeature` pre-fills the path using `Project.worktreesDirectory ?? "\(project.rootPath)-worktrees/\(branch)"`; if a matching path already exists, disambiguate with a short UUID suffix (same rule as exec-plan 0002 M6).

Add destructive confirmation via `AlertState`:

    state.confirmRemoveAlert = AlertState {
      TextState("Remove Worktree \"\(worktree.name)\"?")
    } actions: {
      ButtonState(role: .destructive, action: .confirm(.worktree(worktreeID, projectID))) { TextState("Remove") }
      ButtonState(role: .cancel) { TextState("Cancel") }
    }

The confirm action routes to `hierarchyClient.removeWorktree`.

Add an empty-Tab placeholder: when `activeTab.panels.isEmpty`, `SplitViewportView` renders a centered `VStack { Text("No panels"); Button("New Panel") { store.send(.newPanelButtonTapped(atPanelID: nil, direction: .right)) } }`.

Delete `apps/mac/touch-code/App/MainView.swift` and `apps/mac/touch-code/App/MainView+SingleSurfaceHost.swift` (M5's helper). Run `grep -r MainView apps/mac/touch-code` to verify no remaining references. Remove `SingleSurfaceHostTests.swift`.

Add `apps/mac/touch-code/Tests/CreationModalsTests.swift` covering each sheet's submit path and the destructive-alert confirm / cancel flows.

**Observable acceptance.** Fresh install (no `catalog.json`). Launch: sidebar is empty. Click "New Space" button (toolbar): sheet opens; enter "work"; click Create. Sidebar shows the Space. Click "Add Project"; pick a git repo; Project appears with an auto-created default Worktree. Click "New Worktree" on that Project; enter "exp/test"; submit. `git -C <repo> worktree list` lists it. Right-click the Worktree → Remove → confirm alert → `git worktree list` no longer shows it. Quit. Relaunch. Every Space / Project / Worktree / Tab / Panel is present; shells are freshly started; split geometry matches. Tests: 60 passing.

**Expected commits.** Three commits: `feat(app): creation sheets for Space/Project/Worktree/Tab (TCA Shell M6)`, `feat(app): destructive confirmation alerts (TCA Shell M6)`, `chore(app): delete MainView + SingleSurfaceHost — shell is self-sufficient (TCA Shell M6)`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/touch-code`) unless otherwise noted. Each milestone follows the same verification ritual: build, lint, test, manual smoke (where relevant).

### Per-milestone verification

    make mac-generate
    make mac-build
    make mac-lint
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-code | xcbeautify | tail -5
    # Expected tail: "Test run with N tests in M suites passed after …"

### M2 smoke (visible shell)

    make mac-run-app &
    sleep 3
    # Expected: window opens with two empty columns; no segfault.
    pkill -f touch_code

### M6 end-to-end smoke (fresh install)

    mv ~/.config/touch-code/catalog.json ~/.config/touch-code/catalog.json.bak 2>/dev/null || true
    make mac-run-app
    # In the app: toolbar "New Space" → "work"; "Add Project" → pick repo;
    # "New Worktree" → "exp/tca-shell"; "New Tab" → "New Panel"; split right.
    git -C /Users/wanggang/dev/00/touch-code worktree list
    # Expected: exp/tca-shell listed at <repo>-worktrees/exp/tca-shell
    # Quit, relaunch, verify layout restored.

## Validation and Acceptance

After all six milestones land, a contributor can perform the following and observe the exact outputs:

1. `make mac-bootstrap && make mac-generate && make mac-build && make mac-run-app`. The app window opens within 1 s.
2. The sidebar is empty on first launch. Click "New Space" from the toolbar; enter a name; submit. The Space appears in the sidebar.
3. Click "Add Project"; pick a git repository folder. The Project appears; `Project.gitRoot` is non-nil and a default Worktree is auto-created on the current branch.
4. Select the Worktree. The detail column shows an empty tab bar and a placeholder "No panels in this Tab". Click "New Tab"; a Tab appears and is selected. Click "New Panel"; a live libghostty shell renders.
5. Split the Panel horizontally. Two panes are alive and independently focused.
6. Cmd-Q the app. Relaunch. Every Space / Project / Worktree / Tab / Panel is present; shells are freshly started; split geometry matches exactly.
7. All test schemes pass:

        xcodebuild test -scheme touch-code  # expected: 60+ tests pass

8. `make mac-lint` is clean.
9. `grep -r SingleSurfaceHost\\\|MainView apps/mac/touch-code/` returns no matches (shell is self-sufficient).

Failure on any of the above blocks sign-off; the plan is not complete until all nine are green.

## Idempotence and Recovery

Every milestone is designed to be re-runnable without state leakage.

- **Regenerate workspace.** `make mac-generate` is a pure function of `Project.swift` + `Tuist/Package.swift`; safe to repeat.
- **Clean build.** `make mac-clean-build` (or `rm -rf apps/mac/Derived && make mac-generate && make mac-build`) resets DerivedData without touching sources.
- **Reset catalog.** `mv ~/.config/touch-code/catalog.json ~/.config/touch-code/catalog.json.bak` forces a fresh hierarchy on next launch. Shipped load path (M2 of exec-plan 0002) backs broken files automatically, so this is rarely needed manually.
- **Drop a stuck worktree.** If M6 smoke leaves orphan git worktrees: `git -C /Users/wanggang/dev/00/touch-code worktree list` to enumerate, then `git worktree remove <path> --force` to drop.
- **Revert to pre-shell state.** If the TCA shell is unstable, revert `TouchCodeApp.body` to mount `MainView()`; all feature files remain but are unreachable. One-commit revert.

No step modifies system-wide state (no `sudo`, no `xcode-select`, no global Git config, no PATH mutation).

## Artifacts and Notes

Notes from the pre-plan prototyping / research phase:

- **TCA 1.23.1 confirmed compatible.** Both reference projects (`supacode`, `supaterm`) ship `exact: "1.23.1"`; no breaking changes on 1.24 / 1.25 that would block us.
- **Event-stream consumer pattern.** supacode routes `terminalClient.events()` into `AppFeature.Action.terminalEvent(TerminalClient.Event)` via a long-running `Effect.run` cancelled by `CancelID`. We adopt the same shape for our single `RootFeature.Action.engineEvent(TerminalEvent)` case. Subscription is re-armable: if the effect is cancelled and re-armed, `TerminalEngine.events()` returns a fresh subscriber stream thanks to the M4.4 `SubscriberRegistry`.
- **Environment vs Dependency injection.** SwiftUI `@Environment(HierarchyManager.self)` propagates the manager to views without passing through TCA state. `@Dependency(\.hierarchyClient)` propagates it to reducers. Both reach the same shipped object; the split keeps reducer code free of SwiftUI environment concerns and vice-versa.
- **NavigationSplitView on macOS 13+ floor.** Product spec pins the floor at macOS 13 Ventura; `NavigationSplitView` requires macOS 13+ — no back-compat required.
- **PanelHostView already complete.** The shipped `PanelHostView` in `App/PanelHostView.swift` accepts a `PanelSurface` and renders its `view`. M4 consumes it unchanged.

## Interfaces and Dependencies

The following types, modules, and signatures must exist by plan completion. Names are binding — later plans and features will reference them.

**External dependencies added by this plan** (in `apps/mac/Tuist/Package.swift`):

- `swift-composable-architecture` pinned to `1.23.1` (matching supacode / supaterm).
- No other new external deps.

**`apps/mac/touch-code/App/Clients/`** (TCA dependency-injection bridge):

    struct HierarchyClient: Sendable {
      var createSpace: @MainActor @Sendable (_ name: String) -> SpaceID
      var renameSpace: @MainActor @Sendable (_ id: SpaceID, _ name: String) throws -> Void
      var removeSpace: @MainActor @Sendable (_ id: SpaceID) throws -> Void
      var addProject: @MainActor @Sendable (_ spaceID: SpaceID, _ name: String, _ rootPath: String, _ gitRoot: String?) throws -> ProjectID
      var removeProject: @MainActor @Sendable (_ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var createWorktree: @MainActor @Sendable (_ projectID: ProjectID, _ spaceID: SpaceID, _ name: String, _ path: String, _ branch: String?) throws -> WorktreeID
      var removeWorktree: @MainActor @Sendable (_ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var selectSpace: @MainActor @Sendable (_ id: SpaceID?) -> Void
      var selectProject: @MainActor @Sendable (_ id: ProjectID?, _ inSpace: SpaceID) -> Void
      var selectWorktree: @MainActor @Sendable (_ id: WorktreeID?, _ inProject: ProjectID, _ inSpace: SpaceID) -> Void
      var createTab: @MainActor @Sendable (_ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID, _ name: String?) throws -> TabID
      var closeTab: @MainActor @Sendable (_ id: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var selectTab: @MainActor @Sendable (_ id: TabID?, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) -> Void
      var openPanel: @MainActor @Sendable (_ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID, _ workingDirectory: String, _ initialCommand: String?) throws -> PanelID
      var splitPanel: @MainActor @Sendable (_ panelID: PanelID, _ direction: SplitTree<PanelID>.NewDirection, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID, _ workingDirectory: String, _ initialCommand: String?) throws -> PanelID
      var closePanel: @MainActor @Sendable (_ panelID: PanelID, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var focusPanel: @MainActor @Sendable (_ panelID: PanelID, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var resizeSplit: @MainActor @Sendable (_ path: SplitTree<PanelID>.Path, _ ratio: Double, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var snapshot: @MainActor @Sendable () -> Catalog
      /// Coarse selection-change stream. Emits a tuple of the currently
      /// selected (space, project, worktree) whenever any of those IDs
      /// changes in the catalog. Downstream reducers (C6 inbox scoping,
      /// C7 GitViewerFeature, C8 editor-settings scoping) subscribe to
      /// react on worktree switches without holding a reference to the
      /// @Observable HierarchyManager. Emitted coarsely — one event per
      /// change, deduped against the last snapshot.
      var selectionChanges: @MainActor @Sendable () -> AsyncStream<HierarchySelection>
    }

    struct HierarchySelection: Equatable, Sendable {
      let spaceID: SpaceID?
      let projectID: ProjectID?
      let worktreeID: WorktreeID?
    }
    extension HierarchyClient: DependencyKey {
      static let liveValue: HierarchyClient
      static let testValue: HierarchyClient
    }
    extension DependencyValues {
      var hierarchyClient: HierarchyClient { … }
    }

    struct TerminalClient: Sendable {
      var sendInput: @MainActor @Sendable (_ panelID: PanelID, _ text: String) -> Void
      var setFocus: @MainActor @Sendable (_ panelID: PanelID, _ focused: Bool) -> Void
      var retryPanel: @MainActor @Sendable (_ panelID: PanelID) -> Bool
      var ensureSurface: @MainActor @Sendable (_ panelID: PanelID, _ tabID: TabID, _ worktreeID: WorktreeID, _ projectID: ProjectID, _ spaceID: SpaceID) throws -> Void
      var closeSurface: @MainActor @Sendable (_ panelID: PanelID) -> Void
      var events: @MainActor @Sendable () -> AsyncStream<TerminalEvent>
    }
    extension TerminalClient: DependencyKey { … }
    extension DependencyValues { var terminalClient: TerminalClient { … } }

**`apps/mac/touch-code/App/Features/Root/`**:

    @Reducer struct RootFeature {
      @ObservableState struct State: Equatable {
        var sidebar: HierarchySidebarFeature.State
        var detail:  WorktreeDetailFeature.State
        @Presents var confirmRemoveAlert: AlertState<ConfirmRemoveAction>?
      }
      enum Action: Equatable {
        case onLaunch
        case engineEvent(TerminalEvent)
        case sidebar(HierarchySidebarFeature.Action)
        case detail(WorktreeDetailFeature.Action)
        case confirmRemoveAlert(PresentationAction<ConfirmRemoveAction>)
      }
    }

**`apps/mac/touch-code/App/Features/HierarchySidebar/`**:

    @Reducer struct HierarchySidebarFeature {
      @ObservableState struct State: Equatable {
        var expandedSpaceIDs: Set<SpaceID> = []
        var expandedProjectIDs: Set<ProjectID> = []
        @Presents var newSpaceSheet: NewSpaceFeature.State?
        @Presents var addProjectSheet: AddProjectFeature.State?
        @Presents var newWorktreeSheet: NewWorktreeFeature.State?
      }
      // actions: spaceRowTapped, projectRowTapped, worktreeRowTapped,
      //          toggleSpaceExpansion, toggleProjectExpansion, + sheet actions
    }

**`apps/mac/touch-code/App/Features/WorktreeDetail/`**, `TabBar/`, `SplitViewport/`: parallel shape — each with a `@Reducer struct` + `@ObservableState` value + action enum. Signatures sketched in M4 above.

**Tuist target changes**:

- `touch-code` target gains `.external(name: "ComposableArchitecture")` dependency.
- `touch-codeTests` target indirectly inherits it via the app dependency.
- No new targets required (all features compile into the app).

**Files deleted by plan completion**:

- `apps/mac/touch-code/App/MainView.swift`
- `apps/mac/touch-code/Tests/SingleSurfaceHostTests.swift`
