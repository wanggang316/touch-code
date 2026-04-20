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
      $0.editorFacade = EditorServiceFacade.testValue
    }

    let selection = HierarchySelection(
      spaceID: SpaceID(),
      projectID: ProjectID(),
      worktreeID: WorktreeID()
    )
    await store.send(.selectionChanged(selection)) { state in
      state.selection = selection
    }
    // Forwarding step: RootFeature turns .selectionChanged into a .gitViewer action.
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
      $0.gitService = GitServiceClient.testValue
      $0.editorFacade = EditorServiceFacade.testValue
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
