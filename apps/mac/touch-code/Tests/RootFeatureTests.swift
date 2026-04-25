import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct RootFeatureTests {
  @Test
  func onLaunchReceivesEngineEventThenCancels() async {
    let (eventStream, eventContinuation) = AsyncStream<TerminalEvent>.makeStream()
    let (selectionStream, selectionContinuation) = AsyncStream<HierarchySelection>.makeStream()

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { eventStream }
      $0.hierarchyClient.selectionChanges = { selectionStream }
    }
    store.exhaustivity = .off

    await store.send(.onLaunch)

    // Yield a single lifecycle event.
    let paneID = PaneID()
    eventContinuation.yield(.paneReady(paneID))
    await store.receive(\.engineEventReceived) { state in
      state.lastEvent = .paneReady
    }

    // Cancellation: onQuit closes the in-flight effects.
    eventContinuation.finish()
    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  @Test
  func selectionChangedUpdatesStateAndForwardsToGitViewer() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      // Snapshot drives both (a) `resolveActiveTab` in this reducer and (b)
      // `GitViewerFeature.worktreePath(in:worktreeID:)` downstream. Return an empty catalog —
      // the test selection points at unknown IDs. resolveActiveTab returns nil; the
      // downstream diff effect discovers no path and dispatches .diffFailed with a clear
      // reason.
      $0.hierarchyClient.snapshot = { Catalog(windows: [], spaces: [], selectedSpaceID: nil) }
      $0.gitService = GitServiceClient.testValue
      $0.editorClient = EditorClient.testValue
    }

    let selection = HierarchySelection(
      spaceID: SpaceID(),
      projectID: ProjectID(),
      worktreeID: WorktreeID()
    )
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
    }
    // Forwarding step: RootFeature turns .selectionChanged into a
    // `.gitViewer(.worktreeSelected)` action. The Header feature does
    // not need a dispatched signal — its badge count reads the live
    // `hierarchyManager.catalog` via `State.unreadCount(in:)`.
    await store.receive(\.gitViewer.worktreeSelected) { state in
      state.gitViewer.projectID = selection.projectID
      state.gitViewer.worktreeID = selection.worktreeID
      state.gitViewer.diffState = .loading
    }
    // Downstream effect: diffRequest fails because the snapshot doesn't contain the
    // worktree, which proves both the forwarding AND the GitViewerFeature is correctly
    // scoped into RootFeature (the reducer ran, not just the action routing).
    await store.receive(\.gitViewer.diffFailed) { state in
      state.gitViewer.diffState = .error(.invalidInput("no worktree path available"))
    }
  }

  @Test
  func selectionChangedMirrorsActiveTabFromSnapshot() async {
    // Build a catalog snapshot with a Worktree whose selectedTabID is a
    // known value; assert the reducer reads through the snapshot and
    // mirrors that TabID into state.detail.splitViewport.activeTabID.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let tab = Tab(id: tabID, name: "t", splitTree: SplitTree(), panes: [])
    let worktree = Worktree(
      id: worktreeID, name: "w", path: "/w", branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktreesDirectory: nil, defaultEditor: nil,
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let space = Space(
      id: spaceID, name: "s", projects: [project], selectedProjectID: projectID
    )
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: spaceID)

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.gitService = GitServiceClient.testValue
      // Worktree path resolves to a live directory in this catalog, so GitViewer reaches
      // `workingTreeDiff`. Stub it with an empty diff — the test is not about the diff.
      $0.gitService.workingTreeDiff = { _, _ in UnifiedDiff(scope: .working, files: []) }
      // 0013 M4 wired a `.gitHub(.projectActivated)` dispatch on projectID transitions.
      // This test is exhaustivity=off and not about GitHub, but the fetch effect still
      // runs and touches .date + remoteInfo + batchPullRequests — stub each to no-op.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
    }
    // Non-exhaustive: this test is about the splitViewport tabID mirror only; the
    // downstream `.gitViewer.worktreeSelected` forwarding + its diff effect are
    // covered by `selectionChangedUpdatesStateAndForwardsToGitViewer`.
    store.exhaustivity = .off

    let selection = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID
    )
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
      state.detail.splitViewport.activeTabID = tabID
    }
  }

  // `inspectorVisibilityTogglesBothWays` removed in T3: replaced by the
  // per-Worktree `gitViewerOverlayVisible` projection and
  // `.gitViewerToggledForCurrentWorktree` action — covered below.

  // MARK: - T3 overlay projection + shortcuts

  /// Shared catalog fixture for T3 GV overlay tests. Worktree A is visible,
  /// B is hidden. The second Worktree lives under the same Project so the
  /// selection delta is just the worktree leg.
  private static func gvFixtureCatalog(
    spaceID: SpaceID, projectID: ProjectID,
    worktreeA: WorktreeID, worktreeB: WorktreeID,
    aVisible: Bool, bVisible: Bool
  ) -> Catalog {
    let wtA = Worktree(
      id: worktreeA, name: "A", path: "/a", branch: "a",
      tabs: [], selectedTabID: nil, gitViewerVisible: aVisible
    )
    let wtB = Worktree(
      id: worktreeB, name: "B", path: "/b", branch: "b",
      tabs: [], selectedTabID: nil, gitViewerVisible: bVisible
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktreesDirectory: nil, defaultEditor: nil,
      worktrees: [wtA, wtB], selectedWorktreeID: worktreeA
    )
    let space = Space(
      id: spaceID, name: "s", projects: [project], selectedProjectID: projectID
    )
    return Catalog(windows: [], spaces: [space], selectedSpaceID: spaceID)
  }

  @Test
  func gitViewerOverlayVisibleTracksSelectionAgainstCatalog() async {
    // With the T3-REV2 single-source-of-truth rewrite, the view reads
    // `State.gitViewerOverlayVisible(in: catalog)` directly. After a
    // `.selectionChanged`, that read returns the target Worktree's
    // persisted `gitViewerVisible` — no reducer projection in between.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      spaceID: spaceID, projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: true, bVisible: false
    )

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.gitService = GitServiceClient.testValue
      $0.gitService.workingTreeDiff = { _, _ in UnifiedDiff(scope: .working, files: []) }
      // 0013 M4: selectionChanged now dispatches .gitHub(.projectActivated) when the
      // Project changes. Stub the downstream deps so exhaustivity=off still runs.
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.gitService.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0[GitHubClient.self].batchPullRequests = { _, _, _, _ in [:] }
      $0.editorClient = EditorClient.testValue
    }
    store.exhaustivity = .off

    // Initially no selection → helper returns false.
    #expect(store.state.gitViewerOverlayVisible(in: catalog) == false)

    let selectionA = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeA
    )
    await store.send(.selectionChanged(selectionA)) { $0.selection = selectionA }
    #expect(store.state.gitViewerOverlayVisible(in: catalog) == true)

    let selectionB = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeB
    )
    await store.send(.selectionChanged(selectionB)) { $0.selection = selectionB }
    #expect(store.state.gitViewerOverlayVisible(in: catalog) == false)
  }

  @Test
  func gitViewerOverlayVisibleFollowsCatalogMutationWithSameSelection() {
    // Second half of the single-source-of-truth contract: flipping the
    // catalog value (T2 Header button path) must flip the helper read
    // without any selection change and without any reducer projection.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeA
    )
    let store = TestStore(initialState: initial) {
      RootFeature()
    }

    let hidden = Self.gvFixtureCatalog(
      spaceID: spaceID, projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: false, bVisible: false
    )
    let shown = Self.gvFixtureCatalog(
      spaceID: spaceID, projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: true, bVisible: false
    )
    #expect(store.state.gitViewerOverlayVisible(in: hidden) == false)
    #expect(store.state.gitViewerOverlayVisible(in: shown) == true)
  }

  @Test
  func gitViewerToggleInvokesHierarchyClientWithFlippedValue() async {
    // The reducer now reads the current value from the catalog snapshot
    // and writes the flipped value; no state mutation. Both entry points
    // (⌘⇧G + Header button) share a single write path.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let catalog = Self.gvFixtureCatalog(
      spaceID: spaceID, projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: false, bVisible: false
    )

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeA
    )

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeGitViewerVisible = { wt, visible in
        recorded.withValue { $0.append((wt, visible)) }
      }
    }

    await store.send(.gitViewerToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.count == 1)
    #expect(recorded.value.first?.0 == worktreeA)
    // Starting from `gitViewerVisible: false`, toggle writes `true`.
    #expect(recorded.value.first?.1 == true)
  }

  @Test
  func gitViewerToggleWithoutSelectionIsNoOp() async {
    // When no Worktree is selected, the toggle must not fire the setter.
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(windows: [], spaces: [], selectedSpaceID: nil) }
      $0.hierarchyClient.setWorktreeGitViewerVisible = { wt, visible in
        recorded.withValue { $0.append((wt, visible)) }
      }
    }
    await store.send(.gitViewerToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.isEmpty)
  }

  @Test
  func openSpaceSwitcherRequestedForwardsToSidebar() async {
    // ⌘K dispatches this; the root reducer forwards to the sidebar via
    // `.externalSpacePopoverOpenRequested` (open-only, not a toggle). The
    // sidebar reducer flips `isSpacePopoverPresented = true`.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    }
    #expect(store.state.sidebar.isSpacePopoverPresented == false)
    await store.send(.openSpaceSwitcherRequested)
    await store.receive(\.sidebar.externalSpacePopoverOpenRequested) { state in
      state.sidebar.isSpacePopoverPresented = true
    }
    // Idempotent: a second dispatch with the popover already open is a no-op
    // on the visible flag (already true).
    await store.send(.openSpaceSwitcherRequested)
    await store.receive(\.sidebar.externalSpacePopoverOpenRequested)
  }

  // MARK: - T2 worktreeHeader delegate routing

  @Test
  func headerOpenEditorWithExplicitIDForwardsToEditor() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? "finder", displayName: "x", binaryPath: nil
        )
      }
    }
    store.exhaustivity = .off

    let projectID = ProjectID()
    await store.send(
      .worktreeHeader(
        .delegate(
          .openEditor(
            editorID: "vscode", worktreePath: "/tmp/w", projectID: projectID
          ))))
    await store.receive(
      .editor(
        .openRequested(
          editorID: "vscode", worktreePath: "/tmp/w", projectID: projectID
        )))
  }

  @Test
  func headerOpenEditorWithNilResolvesDefaultThenForwards() async {
    // Pre-populate EditorFeature cache with a descriptor + matching global
    // default. ResolveDefault should pick "cursor" and the root should
    // re-emit .editor(.openRequested) with that id.
    let descriptor = EditorDescriptor(
      id: "cursor",
      displayName: "Cursor",
      bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      launchMode: .directory,
      appURL: URL(fileURLWithPath: "/Applications/Cursor.app"),
      alternateBundleIdentifiers: []
    )
    var initial = RootFeature.State()
    initial.editor.descriptors = [descriptor]
    initial.editor.globalDefault = "cursor"
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? "finder", displayName: "x", binaryPath: nil
        )
      }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeHeader(
        .delegate(
          .openEditor(
            editorID: nil, worktreePath: "/tmp/w", projectID: nil
          ))))
    await store.receive(
      .editor(
        .openRequested(
          editorID: "cursor", worktreePath: "/tmp/w", projectID: nil
        )))
  }

  @Test
  func headerOpenEditorWithNilDeferspreferredToServiceCascade() async {
    // Codex P2-3: when no project override and no global default resolves, the reducer
    // forwards `nil` as `preferred` so the service's priority cascade picks the first
    // installed editor (Cursor / Zed / VSCode / …) before falling through to Finder.
    // Previously the reducer forced `"finder"` here, which strict-matched Finder and
    // shadowed every higher-priority installed editor.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? "finder", displayName: "x", binaryPath: nil
        )
      }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeHeader(
        .delegate(
          .openEditor(
            editorID: nil, worktreePath: "/tmp/w", projectID: nil
          ))))
    await store.receive(
      .editor(
        .openRequested(
          editorID: nil,
          worktreePath: "/tmp/w",
          projectID: nil
        )))
  }

  @Test
  func headerShowCustomEditorsSettingsInvokesPresenter() async {
    // The Header "+ Custom editors…" delegate now opens the standalone Settings window via
    // `SettingsWindowPresenter` (post Step 6). Test overrides the presenter with a recorder
    // and asserts the closure fires exactly once when the delegate is dispatched.
    let openCount = LockIsolated(0)
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.settingsWindowPresenter = SettingsWindowPresenter(open: {
        openCount.withValue { $0 += 1 }
      })
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeader(.delegate(.showCustomEditorsSettings)))
    await store.finish()
    #expect(openCount.value == 1)
  }
  @Test
  func headerGitViewerToggleDelegateRoutesThroughToggleBranch() async {
    // Nit 1 convergence: the Header GV delegate is consumed by the root
    // reducer and re-dispatched as `.gitViewerToggledForCurrentWorktree`
    // — the same action ⌘⇧G sends. This proves both entry points share
    // one write path (the hierarchyClient mutation is covered by the
    // dedicated `gitViewerToggleInvokesHierarchyClientWithFlippedValue`
    // test; here we only need to prove routing).
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()
    let catalog = Self.gvFixtureCatalog(
      spaceID: spaceID, projectID: projectID,
      worktreeA: worktreeA, worktreeB: worktreeB,
      aVisible: false, bVisible: false
    )

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeA
    )
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeGitViewerVisible = { wt, v in
        recorded.withValue { $0.append((wt, v)) }
      }
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeader(.delegate(.gitViewerToggleRequested)))
    await store.receive(\.gitViewerToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.count == 1)
    #expect(recorded.value.first?.0 == worktreeA)
    #expect(recorded.value.first?.1 == true)
  }

  @Test
  func headerSetProjectOverrideForwardsToEditor() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.setDefaultEditor = { _, _, _ in }
    }
    store.exhaustivity = .off

    let spaceID = SpaceID()
    let projectID = ProjectID()
    await store.send(
      .worktreeHeader(
        .delegate(
          .setProjectOverride(
            projectID: projectID, spaceID: spaceID, editorID: "zed"
          ))))
    await store.receive(
      .editor(
        .setProjectOverride(
          projectID: projectID, spaceID: spaceID, editorID: "zed"
        )))
  }

  // Removed in T1: `sidebarModeChangedUpdatesState` covered the
  // SidebarMode / .sidebarModeChanged plumbing that T0 left as
  // "T2 must either reuse or remove". T1 deleted the plumbing (the
  // sidebar unconditionally renders the hierarchy tree; T2 built the
  // Header bell fresh on WorktreeHeader).

  @Test
  func onLaunchExhaustivelyPropagatesSelectionFromStream() async {
    // Tight-scope TestStore: only the selection stream yields, the event
    // stream immediately finishes. Full exhaustivity verifies that
    // selectionChanged action propagates from the stream subscription
    // through the reducer with no extra actions dispatched.
    let (selectionStream, selectionContinuation) = AsyncStream<HierarchySelection>.makeStream()

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { selectionStream }
      $0.hierarchyClient.snapshot = { Catalog(windows: [], spaces: [], selectedSpaceID: nil) }
      $0.gitService = GitServiceClient.testValue
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.onLaunch)

    // `worktreeID: nil` is the key: when GitViewerFeature receives a nil-worktree selection
    // it resets state without spawning a diff effect, so the test stays exhaustive without
    // any downstream action chain.
    let selection = HierarchySelection(
      spaceID: SpaceID(),
      projectID: nil,
      worktreeID: nil
    )
    selectionContinuation.yield(selection)
    await store.receive(\.selectionChanged) { state in
      state.selection = selection
    }
    // Forwarding reaches GitViewerFeature. Both IDs are nil; state was already all-nil,
    // so the reducer's equality guard at the top of the handler short-circuits with no
    // state mutation. `store.receive` without a mutation closure is still exhaustive —
    // TestStore asserts the action was dispatched, and the state stayed unchanged.
    await store.receive(\.gitViewer.worktreeSelected)

    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  @Test
  func lastEventMarkerCoversAllVariants() {
    // Guard against forgetting to add a marker case when a new TerminalEvent
    // variant lands. Exhaustive switch at the enum level would be safer but
    // requires Equatable which TerminalEvent can't have (Data payload). This
    // test provides at least surface coverage that every variant maps.
    let pane = PaneID()
    let tab = TabID()
    let worktree = WorktreeID()

    let cases: [(TerminalEvent, RootFeature.LastEventMarker)] = [
      (.paneCreated(pane, tab), .paneCreated),
      (.paneReady(pane), .paneReady),
      (.paneOutput(pane, Data([0x01])), .paneOutput),
      (.paneIdle(pane, duration: 1), .paneIdle),
      (.paneExited(pane, code: 0, signal: nil), .paneExited),
      (.paneCrashed(pane, reason: "x"), .paneCrashed),
      (.paneClosedByTab(pane, cause: .other(reason: "x")), .paneClosedByTab),
      (.tabActivated(tab), .tabActivated),
      (.tabAutoClosed(tab, cause: .other(reason: "x")), .tabAutoClosed),
      (.worktreeActivated(worktree), .worktreeActivated),
      (.hierarchyMutated(.catalog), .hierarchyMutated),
    ]
    for (event, expected) in cases {
      #expect(RootFeature.LastEventMarker(event) == expected)
    }
  }

  // MARK: - Tab-bar shortcut resolvers (M2-T2.10)

  /// Builds a catalog with a single worktree carrying `tabCount` tabs;
  /// the `selectedIndex`-th tab is the active one. Each tab has a single
  /// pane so `trailingSplitRequested` paths (and closes in general) find
  /// the runtime surface teardown they expect.
  private static func tabBarFixture(
    tabCount: Int, selectedIndex: Int
  ) -> (SpaceID, ProjectID, WorktreeID, [TabID], Catalog) {
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var tabs: [Tab] = []
    var ids: [TabID] = []
    for i in 0..<tabCount {
      let tabID = TabID()
      let paneID = PaneID()
      let pane = Pane(id: paneID, workingDirectory: "/tmp", initialCommand: nil)
      tabs.append(
        Tab(id: tabID, name: "t\(i)", splitTree: SplitTree(leaf: paneID), panes: [pane])
      )
      ids.append(tabID)
    }
    let worktree = Worktree(
      id: worktreeID, name: "main", path: "/tmp", branch: "main",
      tabs: tabs, selectedTabID: ids[selectedIndex]
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/tmp",
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let space = Space(
      id: spaceID, name: "s", projects: [project], selectedProjectID: projectID
    )
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: spaceID)
    return (spaceID, projectID, worktreeID, ids, catalog)
  }

  @Test
  func newTabForCurrentWorktreeForwardsToTabBar() async {
    let (sp, pr, wt, _, catalog) = Self.tabBarFixture(tabCount: 2, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(spaceID: sp, projectID: pr, worktreeID: wt)

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.createTab = { _, _, _, _ in TabID() }
      // The new-tab reducer auto-spawns a pane in the worktree cwd;
      // stub the call so the unimplemented closure does not record.
      $0.hierarchyClient.openPane = { _, _, _, _, _, _ in PaneID() }
    }
    store.exhaustivity = .off

    await store.send(.newTabForCurrentWorktree)
    await store.receive(\.detail.tabBar)
  }

  @Test
  func newTabForCurrentWorktreeIsNoOpWithoutSelection() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    }
    // No snapshot stub needed — guard short-circuits before any client call.
    await store.send(.newTabForCurrentWorktree)
    await store.finish()
  }

  @Test
  func closeActiveTabForCurrentWorktreeForwardsActiveTab() async {
    let (sp, pr, wt, ids, catalog) = Self.tabBarFixture(tabCount: 3, selectedIndex: 1)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(spaceID: sp, projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.closeTab = { id, _, _, _ in
        captured.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.closeActiveTabForCurrentWorktree)
    await store.receive(\.detail.tabBar)
    #expect(captured.value == ids[1])
  }

  @Test
  func selectTabAtIndexPicksNthTab() async {
    let (sp, pr, wt, ids, catalog) = Self.tabBarFixture(tabCount: 3, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(spaceID: sp, projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.selectTab = { id, _, _, _ in
        captured.withValue { $0 = id }
      }
    }
    store.exhaustivity = .off

    await store.send(.selectTabAtIndexForCurrentWorktree(3))
    await store.receive(\.detail.tabBar)
    #expect(captured.value == ids[2])
  }

  @Test
  func selectTabAtIndexOutOfRangeIsNoOp() async {
    let (sp, pr, wt, _, catalog) = Self.tabBarFixture(tabCount: 2, selectedIndex: 0)
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(spaceID: sp, projectID: pr, worktreeID: wt)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
    }

    // Tab count is 2; asking for the 5th is out of range.
    await store.send(.selectTabAtIndexForCurrentWorktree(5))
    await store.finish()
  }

  @Test
  func selectAdjacentTabCallsClient() async {
    let sp = SpaceID()
    let pr = ProjectID()
    let wt = WorktreeID()
    var initial = RootFeature.State()
    initial.selection = HierarchySelection(spaceID: sp, projectID: pr, worktreeID: wt)

    let captured = LockIsolated<TabAdjacency?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.selectAdjacentTab = { dir, _, _, _ in
        captured.withValue { $0 = dir }
        return nil
      }
    }

    await store.send(.selectAdjacentTabForCurrentWorktree(.next))
    await store.finish()
    #expect(captured.value == .next)
  }
}
