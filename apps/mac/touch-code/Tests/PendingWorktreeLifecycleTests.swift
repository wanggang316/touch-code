import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// TestStore-driven coverage for the pending-row lifecycle inside
/// `HierarchySidebarFeature`. Drives `createWorktreeStream` via a
/// continuation captured per-test so begin / progress / finished /
/// failed / cancel / retry transitions are deterministic without
/// touching `wt`.
@MainActor
struct PendingWorktreeLifecycleTests {
  // MARK: Fixtures

  private static func makeSpec() -> CreateWorktreeSpec {
    CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      name: "feature-x",
      branch: "feature/x",
      baseRef: "origin/main",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
  }

  private static func makePending(
    projectID: ProjectID = ProjectID(),
    spaceID: SpaceID = SpaceID()
  ) -> PendingWorktree {
    PendingWorktree(
      id: PendingWorktreeID(),
      projectID: projectID,
      spaceID: spaceID,
      spec: makeSpec(),
      displayName: "feature/x",
      status: .running,
      lastProgressLine: nil,
      startedAt: Date(timeIntervalSince1970: 0)
    )
  }

  /// Sendable box that holds the stream continuation so the test driver
  /// can yield events from outside the closure that produced the stream.
  private final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _continuation: AsyncThrowingStream<CreateWorktreeEvent, Error>.Continuation?
    func set(_ c: AsyncThrowingStream<CreateWorktreeEvent, Error>.Continuation) {
      lock.lock(); defer { lock.unlock() }
      _continuation = c
    }
    func yield(_ event: CreateWorktreeEvent) {
      lock.lock(); defer { lock.unlock() }
      _continuation?.yield(event)
    }
    func finish(_ error: Error? = nil) {
      lock.lock(); defer { lock.unlock() }
      _continuation?.finish(throwing: error)
    }
  }

  /// Wires the stream-capturing `createWorktreeStream` plus catalog /
  /// select / tab / pane / lifecycle defaults.
  private static func wireDefaults(
    _ deps: inout DependencyValues,
    handle: StreamHandle,
    fixedWorktreeID: WorktreeID = WorktreeID()
  ) {
    deps.gitWorktreeClient.createWorktreeStream = { _ in
      AsyncThrowingStream { continuation in
        handle.set(continuation)
      }
    }
    deps.hierarchyClient.createWorktreeWithGit = { _, _, _, _, _ in fixedWorktreeID }
    deps.hierarchyClient.selectWorktree = { _, _, _ in }
    deps.hierarchyClient.createTab = { _, _, _, _ in TabID() }
    deps.hierarchyClient.openPane = { _, _, _, _, _, _ in PaneID() }
    deps.hierarchyClient.runWorktreeLifecycleScript = { _, _, _ in .skipped }
  }

  // MARK: Tests

  @Test
  func pendingFullLifecycle() async {
    let pending = Self.makePending()
    let handle = StreamHandle()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { Self.wireDefaults(&$0, handle: handle) }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending)) {
      $0.pendingWorktrees.append(pending)
    }

    handle.yield(.progressLine("1/3 fetching"))
    await store.receive(\.pendingWorktreeProgress) {
      $0.pendingWorktrees[id: pending.id]?.lastProgressLine = "1/3 fetching"
    }

    let url = URL(fileURLWithPath: "/tmp/repo/.worktrees/feature-x")
    handle.yield(.finished(worktreePath: url))
    await store.receive(\.pendingWorktreeFinished) {
      $0.pendingWorktrees.remove(id: pending.id)
    }
    await store.receive(\.delegate.lifecycleScriptResult)
  }

  @Test
  func pendingFailureSurfacedAsFailedStatus() async {
    let pending = Self.makePending()
    let handle = StreamHandle()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { Self.wireDefaults(&$0, handle: handle) }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    handle.finish(GitWorktreeError.branchExists("feature/x"))
    await store.receive(\.pendingWorktreeFailed) {
      $0.pendingWorktrees[id: pending.id]?.status = .failed(.branchExists("feature/x"))
    }
  }

  @Test
  func pendingFailedRetryRestartsStream() async {
    var pending = Self.makePending()
    pending.status = .failed(.branchExists("feature/x"))
    let handle = StreamHandle()
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)

    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: { Self.wireDefaults(&$0, handle: handle) }
    store.exhaustivity = .off

    await store.send(.pendingWorktreeRetryTapped(pending.id)) {
      $0.pendingWorktrees[id: pending.id]?.status = .running
      $0.pendingWorktrees[id: pending.id]?.lastProgressLine = nil
    }

    let url = URL(fileURLWithPath: "/tmp/repo/.worktrees/feature-x")
    handle.yield(.finished(worktreePath: url))
    await store.receive(\.pendingWorktreeFinished) {
      $0.pendingWorktrees.remove(id: pending.id)
    }
    await store.receive(\.delegate.lifecycleScriptResult)
  }

  @Test
  func pendingCancelRemovesRowAndCancelsEffect() async {
    let pending = Self.makePending()
    let handle = StreamHandle()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { Self.wireDefaults(&$0, handle: handle) }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    handle.yield(.progressLine("step 1"))
    await store.receive(\.pendingWorktreeProgress)

    await store.send(.pendingWorktreeCancelTapped(pending.id)) {
      $0.pendingWorktrees.remove(id: pending.id)
    }
    await store.finish()
  }

  @Test
  func pendingCancelFinishedRaceFinishedIsNoop() async {
    let pending = Self.makePending()
    let handle = StreamHandle()
    let createCalls = LockIsolated(0)
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.wireDefaults(&deps, handle: handle)
      deps.hierarchyClient.createWorktreeWithGit = { _, _, _, _, _ in
        createCalls.withValue { $0 += 1 }
        return WorktreeID()
      }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    await store.send(.pendingWorktreeCancelTapped(pending.id)) {
      $0.pendingWorktrees.remove(id: pending.id)
    }
    // Manually inject finished after cancel — guard must drop it.
    await store.send(
      .pendingWorktreeFinished(pending.id, URL(fileURLWithPath: "/tmp/x")))
    #expect(createCalls.value == 0)
    await store.finish()
  }

  @Test
  func pendingCapRejectsBeyondEight() async {
    let projectID = ProjectID()
    let spaceID = SpaceID()
    var initial = HierarchySidebarFeature.State()
    for _ in 0..<8 {
      initial.pendingWorktrees.append(Self.makePending(projectID: projectID, spaceID: spaceID))
    }
    let handle = StreamHandle()
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: { Self.wireDefaults(&$0, handle: handle) }
    store.exhaustivity = .off

    let ninth = Self.makePending(projectID: projectID, spaceID: spaceID)
    await store.send(.beginPendingWorktreeCreation(ninth))
    #expect(store.state.pendingWorktrees.count == 8)
    #expect(store.state.pendingWorktrees[id: ninth.id] == nil)
  }

  @Test
  func pendingCatalogWriteFailureKeepsRowAsFailed() async {
    let pending = Self.makePending()
    let handle = StreamHandle()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.wireDefaults(&deps, handle: handle)
      deps.hierarchyClient.createWorktreeWithGit = { _, _, _, _, _ in
        throw GitWorktreeError.commandFailed(command: "catalog", stderr: "boom")
      }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    handle.yield(.finished(worktreePath: URL(fileURLWithPath: "/tmp/x")))
    await store.receive(\.pendingWorktreeFinished) { state in
      state.pendingWorktrees[id: pending.id]?.status = .failed(
        .commandFailed(command: "catalog", stderr: "boom"))
    }
    #expect(store.state.pendingWorktrees[id: pending.id] != nil)
  }

  @Test
  func pendingOpenPaneFailureStillRemovesRow() async {
    let pending = Self.makePending()
    let handle = StreamHandle()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.wireDefaults(&deps, handle: handle)
      deps.hierarchyClient.createTab = { _, _, _, _ in
        throw GitWorktreeError.commandFailed(command: "createTab", stderr: "boom")
      }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    handle.yield(.finished(worktreePath: URL(fileURLWithPath: "/tmp/x")))
    await store.receive(\.pendingWorktreeFinished) {
      $0.pendingWorktrees.remove(id: pending.id)
    }
    #expect(store.state.pendingWorktrees[id: pending.id] == nil)
    await store.receive(\.delegate.lifecycleScriptResult)
  }
}
