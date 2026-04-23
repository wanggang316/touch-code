import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// TestStore coverage for GitHubFeature. Exercises every action path with stubbed
/// GitHubClient closures. No network, no gh subprocess.
@MainActor
struct GitHubFeatureTests {
  // MARK: - availability

  @Test
  func onAppearProbesAvailabilityAndStoresResult() async {
    let store = Self.makeStore { client in
      client.availability = { .available(host: "github.com", user: "gump") }
    }
    await store.send(.onAppear)
    await store.receive {
      if case .availabilityProbed(.available, _) = $0 { return true }
      return false
    } assert: {
      $0.availability = .available(host: "github.com", user: "gump")
      $0.availabilityProbedAt = Self.fixedDate
    }
  }

  @Test
  func onAppearWithinFreshnessWindowSkipsProbe() async {
    var seed = GitHubFeature.State()
    seed.availability = .available(host: "github.com", user: "gump")
    seed.availabilityProbedAt = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.availability = {
        Issue.record("availability should not be called inside the 30 s window")
        return .unknown
      }
    }
    await store.send(.onAppear)
  }

  @Test
  func refreshAvailabilityAlwaysReprobes() async {
    var seed = GitHubFeature.State()
    seed.availability = .available(host: "github.com", user: "gump")
    seed.availabilityProbedAt = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.availability = { .unavailable(reason: "gh missing") }
    }
    await store.send(.refreshAvailabilityRequested) {
      $0.availabilityProbedAt = nil
    }
    await store.receive {
      if case .availabilityProbed(.unavailable, _) = $0 { return true }
      return false
    } assert: {
      $0.availability = .unavailable(reason: "gh missing")
      $0.availabilityProbedAt = Self.fixedDate
    }
  }

  // MARK: - snapshot loading

  @Test
  func worktreeBecameVisibleLoadsSnapshot() async {
    let expected = Self.stubSnapshot(number: 42)
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.pullRequest = { _, _ in expected }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "feature", worktreePath: Self.path)) {
      $0.loading.insert(wid)
    }
    await store.receive(.snapshotLoaded(wid, .success(expected))) {
      $0.loading.remove(wid)
      $0.snapshots[wid] = expected
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.lastError[wid] = nil
    }
  }

  @Test
  func worktreeBecameVisibleSkipsWhenCached() async {
    let snap = Self.stubSnapshot(number: 1)
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    seed.snapshotLoadedAt[wid] = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.pullRequest = { _, _ in
        Issue.record("pullRequest must not be called when cache is fresh")
        return nil
      }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "b", worktreePath: Self.path))
  }

  @Test
  func worktreeBecameVisibleWhenLoadingIsNoop() async {
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.loading.insert(wid)
    let store = Self.makeStore(initialState: seed) { client in
      client.pullRequest = { _, _ in
        Issue.record("pullRequest must not be called when a fetch is already in flight")
        return nil
      }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "b", worktreePath: Self.path))
  }

  @Test
  func refreshRequestedForcesReload() async {
    let existing = Self.stubSnapshot(number: 1)
    let refreshed = Self.stubSnapshot(number: 1, title: "updated")
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = existing
    seed.snapshotLoadedAt[wid] = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.pullRequest = { _, _ in refreshed }
    }
    await store.send(.refreshRequested(wid, branch: "b", worktreePath: Self.path)) {
      $0.snapshotLoadedAt[wid] = nil
      $0.loading.insert(wid)
    }
    await store.receive(.snapshotLoaded(wid, .success(refreshed))) {
      $0.loading.remove(wid)
      $0.snapshots[wid] = refreshed
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
  }

  @Test
  func snapshotFailurePopulatesLastError() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.pullRequest = { _, _ in throw GitHubError.notAuthenticated(host: "github.com") }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "b", worktreePath: Self.path)) {
      $0.loading.insert(wid)
    }
    await store.receive {
      if case .snapshotLoaded(let w, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.loading.remove(wid)
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.lastError[wid] = .notAuthenticated(host: "github.com")
    }
  }

  @Test
  func snapshotLoadedWithNilPRClearsCachedSnapshot() async {
    let existing = Self.stubSnapshot(number: 1)
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = existing
    seed.loading.insert(wid)
    let store = Self.makeStore(initialState: seed)
    await store.send(.snapshotLoaded(wid, .success(nil))) {
      $0.snapshots[wid] = nil
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.loading = []
      $0.lastError[wid] = nil
    }
  }

  // MARK: - popover

  @Test
  func presentPopoverWithCachedSnapshotFetchesChecksAndRun() async {
    let wid = WorktreeID()
    let snap = Self.stubSnapshot(number: 42, headRefName: "feature/github01")
    let check = CheckResult(name: "build", status: .completed, conclusion: .success)
    let run = Self.stubRun(runID: 99)
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    let store = Self.makeStore(initialState: seed) { client in
      client.checks = { prNumber, _ in
        #expect(prNumber == 42)
        return [check]
      }
      client.latestWorkflowRun = { branch, _ in
        #expect(branch == "feature/github01")
        return run
      }
    }
    await store.send(.presentPopover(wid, worktreePath: Self.path)) {
      $0.popoverTarget = wid
    }
    await store.receive(.checksLoaded(prNumber: 42, .success([check]))) {
      $0.checks[42] = [check]
    }
    await store.receive(.workflowRunLoaded(prNumber: 42, .success(run))) {
      $0.latestWorkflowRuns[42] = run
    }
  }

  @Test
  func dismissPopoverClearsTarget() async {
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.popoverTarget = wid
    let store = Self.makeStore(initialState: seed)
    await store.send(.dismissPopover) {
      $0.popoverTarget = nil
    }
  }

  // MARK: - merge

  @Test
  func mergeSucceededEmitsDelegate() async {
    let wid = WorktreeID()
    let snap = Self.stubSnapshot(number: 99, state: .open)
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { prNumber, strategy, _ in
        #expect(prNumber == 99)
        #expect(strategy == .squash)
      }
    }
    await store.send(.mergeRequested(wid, prNumber: 99, strategy: .squash, worktreePath: Self.path))
    await store.receive(.mergeCompleted(wid, prNumber: 99, .success(.init())))
    await store.receive(.delegate(.pullRequestMerged(wid, snapshot: snap)))
  }

  @Test
  func mergeFailureSurfacesMergeConflict() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.merge = { _, _, _ in throw GitHubError.mergeConflict }
    }
    await store.send(.mergeRequested(wid, prNumber: 1, strategy: .squash, worktreePath: Self.path))
    await store.receive {
      if case .mergeCompleted(let w, 1, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.lastError[wid] = .mergeConflict
    }
  }

  @Test
  func closeDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.close = { prNumber, _ in #expect(prNumber == 7) }
    }
    await store.send(.closeRequested(wid, prNumber: 7, worktreePath: Self.path))
    await store.receive(.closeCompleted(wid, .success(.init())))
  }

  @Test
  func markReadyDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.markReady = { prNumber, _ in #expect(prNumber == 11) }
    }
    await store.send(.markReadyRequested(wid, prNumber: 11, worktreePath: Self.path))
    await store.receive(.markReadyCompleted(wid, .success(.init())))
  }

  @Test
  func rerunFailedJobsDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.rerunFailedJobs = { runID, _ in #expect(runID == 123) }
    }
    await store.send(.rerunFailedJobsRequested(wid, runID: 123, worktreePath: Self.path))
    await store.receive(.rerunFailedJobsCompleted(wid, .success(.init())))
  }

  @Test
  func rerunFailedJobsFailurePopulatesLastError() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.rerunFailedJobs = { _, _ in throw GitHubError.network("dns fail") }
    }
    await store.send(.rerunFailedJobsRequested(wid, runID: 1, worktreePath: Self.path))
    await store.receive {
      if case .rerunFailedJobsCompleted(let w, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.lastError[wid] = .network("dns fail")
    }
  }

  // MARK: - state helper

  @Test
  func worktreeForPRNumberResolvesFromSnapshots() {
    var state = GitHubFeature.State()
    let wid = WorktreeID()
    state.snapshots[wid] = Self.stubSnapshot(number: 42)
    #expect(state.worktree(for: 42) == wid)
    #expect(state.worktree(for: 99) == nil)
  }

  // MARK: - Fixtures

  private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
  private static let path = URL(fileURLWithPath: "/tmp/touch-code-test")

  private static func stubSnapshot(
    number: Int = 1,
    title: String = "Test PR",
    state: PullRequestState = .open,
    headRefName: String = "feature/test"
  ) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: number,
      title: title,
      state: state,
      isDraft: false,
      headRefName: headRefName,
      author: "gump",
      additions: 0,
      deletions: 0,
      commitCount: 1,
      mergeable: .mergeable,
      url: URL(string: "https://github.com/w/r/pull/\(number)")!,
      updatedAt: fixedDate
    )
  }

  private static func stubRun(runID: Int64) -> WorkflowRun {
    WorkflowRun(
      databaseID: runID,
      name: "CI",
      status: .completed,
      conclusion: .success,
      headBranch: "feature/test",
      headSHA: "abc",
      runNumber: 1,
      updatedAt: fixedDate,
      url: URL(string: "https://github.com/w/r/actions/runs/\(runID)")!
    )
  }

  private static func makeStore(
    initialState: GitHubFeature.State = .init(),
    customize: @MainActor (inout GitHubClient) -> Void = { _ in }
  ) -> TestStore<GitHubFeature.State, GitHubFeature.Action> {
    TestStore(initialState: initialState) {
      GitHubFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      var client = GitHubClient.testValue
      customize(&client)
      $0[GitHubClient.self] = client
    }
  }
}
