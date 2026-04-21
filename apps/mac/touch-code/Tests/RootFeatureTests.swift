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
      $0.gitService = GitServiceClient.testValue
      // Worktree path resolves to a live directory in this catalog, so GitViewer reaches
      // `workingTreeDiff`. Stub it with an empty diff — the test is not about the diff.
      $0.gitService.workingTreeDiff = { _, _ in UnifiedDiff(scope: .working, files: []) }
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

  @Test
  func selectionChangedRefreshesGitViewerOverlayVisible() async {
    // Catalog with two sibling worktrees: A has gitViewerVisible=true, B has false.
    // Switching selection between them must flip `state.gitViewerOverlayVisible`
    // deterministically via the reducer's `.selectionChanged` branch.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeA = WorktreeID()
    let worktreeB = WorktreeID()

    let wtA = Worktree(
      id: worktreeA, name: "A", path: "/a", branch: "a",
      tabs: [], selectedTabID: nil, gitViewerVisible: true
    )
    let wtB = Worktree(
      id: worktreeB, name: "B", path: "/b", branch: "b",
      tabs: [], selectedTabID: nil, gitViewerVisible: false
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktreesDirectory: nil, defaultEditor: nil,
      worktrees: [wtA, wtB], selectedWorktreeID: worktreeA
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
      $0.gitService.workingTreeDiff = { _, _ in UnifiedDiff(scope: .working, files: []) }
      $0.editorClient = EditorClient.testValue
    }
    store.exhaustivity = .off

    let selectionA = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeA
    )
    await store.send(.selectionChanged(selectionA)) { state in
      state.selection = selectionA
      state.gitViewerOverlayVisible = true
    }

    let selectionB = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeB
    )
    await store.send(.selectionChanged(selectionB)) { state in
      state.selection = selectionB
      state.gitViewerOverlayVisible = false
    }
  }

  @Test
  func gitViewerToggleUpdatesStateAndCallsHierarchyClient() async {
    // Arrange a selection and a recording `setWorktreeGitViewerVisible` closure;
    // toggling optimistically flips state and fires the persist setter.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID
    )
    initial.gitViewerOverlayVisible = false

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.setWorktreeGitViewerVisible = { wt, visible in
        recorded.withValue { $0.append((wt, visible)) }
      }
    }

    await store.send(.gitViewerToggledForCurrentWorktree) { state in
      state.gitViewerOverlayVisible = true
    }
    await store.finish()
    #expect(recorded.value.count == 1)
    #expect(recorded.value.first?.0 == worktreeID)
    #expect(recorded.value.first?.1 == true)
  }

  @Test
  func gitViewerToggleWithoutSelectionIsNoOp() async {
    // When no Worktree is selected, the toggle must not mutate state and must
    // not fire the persist setter.
    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.setWorktreeGitViewerVisible = { wt, visible in
        recorded.withValue { $0.append((wt, visible)) }
      }
    }
    await store.send(.gitViewerToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.isEmpty)
  }

  @Test
  func openSpaceSwitcherRequestedBumpsToken() async {
    // ⌘K dispatches this; T1 sidebar observes the monotonic token.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    }
    #expect(store.state.spaceSwitcherOpenToken == 0)
    await store.send(.openSpaceSwitcherRequested) { state in
      state.spaceSwitcherOpenToken = 1
    }
    await store.send(.openSpaceSwitcherRequested) { state in
      state.spaceSwitcherOpenToken = 2
    }
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
      $0.editorClient.open = { _, id, _ in
        EditorChoice(
          id: id ?? "finder", displayName: "x",
          binaryPath: URL(fileURLWithPath: "/bin/x"), argv: []
        )
      }
    }
    store.exhaustivity = .off

    let projectID = ProjectID()
    await store.send(.worktreeHeader(.delegate(.openEditor(
      editorID: "vscode", worktreePath: "/tmp/w", projectID: projectID
    ))))
    await store.receive(.editor(.openRequested(
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
      origin: .builtin,
      template: CommandTemplate(binary: "cursor", args: ["{dir}"]),
      installation: .installed(resolvedBinary: URL(fileURLWithPath: "/usr/local/bin/cursor"))
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
      $0.editorClient.open = { _, id, _ in
        EditorChoice(
          id: id ?? "finder", displayName: "x",
          binaryPath: URL(fileURLWithPath: "/bin/x"), argv: []
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeader(.delegate(.openEditor(
      editorID: nil, worktreePath: "/tmp/w", projectID: nil
    ))))
    await store.receive(.editor(.openRequested(
      editorID: "cursor", worktreePath: "/tmp/w", projectID: nil
    )))
  }

  @Test
  func headerOpenEditorWithNilFallsBackToFinderID() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, id, _ in
        EditorChoice(
          id: id ?? "finder", displayName: "x",
          binaryPath: URL(fileURLWithPath: "/bin/x"), argv: []
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeader(.delegate(.openEditor(
      editorID: nil, worktreePath: "/tmp/w", projectID: nil
    ))))
    await store.receive(.editor(.openRequested(
      editorID: EditorFeature.finderEditorID,
      worktreePath: "/tmp/w",
      projectID: nil
    )))
  }

  @Test
  func headerShowCustomEditorsSettingsOpensSheet() async {
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
    }
    store.exhaustivity = .off

    await store.send(.worktreeHeader(.delegate(.showCustomEditorsSettings)))
    await store.receive(\.settingsSheetShown) { state in
      state.settingsSheet = SettingsSheetFeature.State()
    }
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
    await store.send(.worktreeHeader(.delegate(.setProjectOverride(
      projectID: projectID, spaceID: spaceID, editorID: "zed"
    ))))
    await store.receive(.editor(.setProjectOverride(
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
