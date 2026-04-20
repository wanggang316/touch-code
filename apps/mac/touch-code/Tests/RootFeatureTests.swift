import ComposableArchitecture
import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

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
    let panelID = PanelID()
    eventContinuation.yield(.panelReady(panelID))
    await store.receive(\.engineEventReceived) { state in
      state.lastEvent = .panelReady
    }

    // Cancellation: onQuit closes the in-flight effects.
    eventContinuation.finish()
    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  @Test
  func selectionChangedUpdatesState() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      // Snapshot is read by the reducer to resolve the active tab for the
      // selection. Return an empty catalog — the test selection points at
      // unknown IDs, so resolveActiveTab returns nil and activeTabID stays
      // at its default.
      $0.hierarchyClient.snapshot = { Catalog(windows: [], spaces: [], selectedSpaceID: nil) }
    }

    let selection = HierarchySelection(
      spaceID: SpaceID(),
      projectID: ProjectID(),
      worktreeID: WorktreeID()
    )
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
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

    let tab = Tab(id: tabID, name: "t", splitTree: SplitTree(), panels: [])
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
    }

    let selection = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID
    )
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
      state.detail.splitViewport.activeTabID = tabID
    }
  }

  @Test
  func inspectorVisibilityTogglesBothWays() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
    }

    #expect(!store.state.inspectorVisible)
    await store.send(.inspectorVisibilityToggled) { $0.inspectorVisible = true }
    await store.send(.inspectorVisibilityToggled) { $0.inspectorVisible = false }
  }

  @Test
  func sidebarModeChangedUpdatesState() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
    }

    #expect(store.state.sidebarMode == .hierarchy)
    await store.send(.sidebarModeChanged(.inbox)) { state in
      state.sidebarMode = .inbox
    }
    await store.send(.sidebarModeChanged(.hierarchy)) { state in
      state.sidebarMode = .hierarchy
    }
  }

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
    }

    await store.send(.onLaunch)

    let selection = HierarchySelection(
      spaceID: SpaceID(),
      projectID: nil,
      worktreeID: nil
    )
    selectionContinuation.yield(selection)
    await store.receive(\.selectionChanged) { state in
      state.selection = selection
    }

    selectionContinuation.finish()
    await store.send(.onQuit)
  }

  @Test
  func lastEventMarkerCoversAllVariants() {
    // Guard against forgetting to add a marker case when a new TerminalEvent
    // variant lands. Exhaustive switch at the enum level would be safer but
    // requires Equatable which TerminalEvent can't have (Data payload). This
    // test provides at least surface coverage that every variant maps.
    let panel = PanelID()
    let tab = TabID()
    let worktree = WorktreeID()

    let cases: [(TerminalEvent, RootFeature.LastEventMarker)] = [
      (.panelCreated(panel, tab), .panelCreated),
      (.panelReady(panel), .panelReady),
      (.panelOutput(panel, Data([0x01])), .panelOutput),
      (.panelIdle(panel, duration: 1), .panelIdle),
      (.panelExited(panel, code: 0, signal: nil), .panelExited),
      (.panelCrashed(panel, reason: "x"), .panelCrashed),
      (.panelClosedByTab(panel, cause: .other(reason: "x")), .panelClosedByTab),
      (.tabActivated(tab), .tabActivated),
      (.tabAutoClosed(tab, cause: .other(reason: "x")), .tabAutoClosed),
      (.worktreeActivated(worktree), .worktreeActivated),
      (.hierarchyMutated(.catalog), .hierarchyMutated),
    ]
    for (event, expected) in cases {
      #expect(RootFeature.LastEventMarker(event) == expected)
    }
  }
}
