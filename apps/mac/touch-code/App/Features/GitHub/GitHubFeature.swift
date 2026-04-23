import ComposableArchitecture
import Foundation
import TouchCodeCore
import os.log

/// TCA reducer owning the GitHub integration's per-app state — availability probe result,
/// per-Worktree PR snapshots (with check + workflow-run detail), popover presentation bit,
/// and per-Worktree last-error for the inline banner.
///
/// State is **memory-only** — nothing is persisted. On relaunch, everything reloads from
/// `gh` on first-view. See exec-plan 0012 M3.
///
/// Mutations flow through explicit Requested → Completed action pairs (merge /
/// close / markReady / rerunFailedJobs). The Completed branch debounces a per-Worktree
/// `refreshRequested` to pick up the new server state without hammering gh.
@Reducer
struct GitHubFeature {
  @ObservableState
  struct State: Equatable {
    var availability: GitHubAvailability = .unknown
    var availabilityProbedAt: Date?

    var snapshots: [WorktreeID: PullRequestSnapshot] = [:]
    var snapshotLoadedAt: [WorktreeID: Date] = [:]

    /// Check list keyed by PR number — a Worktree's checks are fetched alongside its
    /// snapshot when the popover opens.
    var checks: [Int: [CheckResult]] = [:]

    /// Latest workflow run keyed by PR number. Seeds the "Rerun failed jobs" action.
    var latestWorkflowRuns: [Int: WorkflowRun] = [:]

    var loading: Set<WorktreeID> = []

    /// Mutation operations in flight per Worktree. Views observe this to disable the
    /// matching popover button so repeated clicks can't fire multiple `gh` subprocesses.
    var mutating: Set<WorktreeID> = []

    /// Worktree paths observed via `worktreeBecameVisible` / `refreshRequested` /
    /// `presentPopover`. Stashed here so post-mutation refresh effects can re-issue a
    /// `refreshRequested` without the completed action having to carry the path.
    var worktreePaths: [WorktreeID: URL] = [:]

    /// Which Worktree's popover is visible. `nil` ⇒ no popover.
    var popoverTarget: WorktreeID?

    /// Per-Worktree last-seen error, cleared on successful refresh.
    var lastError: [WorktreeID: GitHubError] = [:]

    /// PR-number ↔ Worktree map derived from `snapshots`. Keeps lookup O(1) for action
    /// completion handlers that only know the PR number.
    func worktree(for prNumber: Int) -> WorktreeID? {
      snapshots.first(where: { $0.value.number == prNumber })?.key
    }
  }

  enum Action: Equatable {
    case onAppear
    case refreshAvailabilityRequested
    case availabilityProbed(GitHubAvailability, probedAt: Date)

    case worktreeBecameVisible(WorktreeID, branch: String, worktreePath: URL)
    case refreshRequested(WorktreeID, branch: String, worktreePath: URL)
    case snapshotLoaded(WorktreeID, TaskResult<PullRequestSnapshot?>)
    case checksLoaded(prNumber: Int, TaskResult<[CheckResult]>)
    case workflowRunLoaded(prNumber: Int, TaskResult<WorkflowRun?>)

    case presentPopover(WorktreeID, worktreePath: URL)
    case dismissPopover

    case mergeRequested(WorktreeID, prNumber: Int, strategy: MergeStrategy, worktreePath: URL)
    case mergeCompleted(WorktreeID, prNumber: Int, TaskResult<VoidSuccess>)

    case closeRequested(WorktreeID, prNumber: Int, worktreePath: URL)
    case closeCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case markReadyRequested(WorktreeID, prNumber: Int, worktreePath: URL)
    case markReadyCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case rerunFailedJobsRequested(WorktreeID, runID: Int64, worktreePath: URL)
    case rerunFailedJobsCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case delegate(Delegate)

    enum Delegate: Equatable {
      /// A merge completed successfully; the parent decides what to do with the Worktree
      /// (archive / delete / ask, per `MergedWorktreeAction`).
      case pullRequestMerged(WorktreeID, snapshot: PullRequestSnapshot)
      /// Palette's "Open Settings" entry — parent presents the Settings window at the
      /// GitHub section.
      case showSettingsGitHub
      /// Open a URL on GitHub in the default browser.
      case openURL(URL)
    }

    /// TaskResult<Void> isn't Equatable because Void isn't. Adopting a trivial sentinel
    /// lets the reducer's Action enum stay Equatable for TestStore. `nonisolated` so the
    /// zero-arg init stays callable from the `@Sendable` effect closures.
    nonisolated struct VoidSuccess: Equatable, Sendable {
      nonisolated init() {}
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case availabilityRefresh
    case snapshot(WorktreeID)
    case checks(prNumber: Int)
    case workflowRun(prNumber: Int)
    /// One-cancellation-slot for all mutations on a Worktree so a second click while an
    /// operation is in flight cancels the prior run rather than racing it.
    case mutation(WorktreeID)
  }

  /// Availability result is treated as fresh for 30 s; subsequent `onAppear` / visibility
  /// dispatches within the window skip the probe.
  static let availabilityFreshness: TimeInterval = 30

  /// Snapshot freshness. Under this, a worktreeBecameVisible is a no-op (already cached).
  static let snapshotFreshness: TimeInterval = 30

  @Dependency(GitHubClient.self) var gitHub
  @Dependency(\.date.now) var now

  private static let logger = Logger(subsystem: "com.touch-code.github", category: "feature")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {

      // MARK: - availability

      case .onAppear:
        if let probedAt = state.availabilityProbedAt,
          now.timeIntervalSince(probedAt) < Self.availabilityFreshness,
          case .available = state.availability
        {
          return .none
        }
        return probeAvailabilityEffect()

      case .refreshAvailabilityRequested:
        state.availabilityProbedAt = nil  // bypass cache
        return probeAvailabilityEffect()

      case .availabilityProbed(let result, let probedAt):
        state.availability = result
        state.availabilityProbedAt = probedAt
        return .none

      // MARK: - snapshot loading

      case .worktreeBecameVisible(let worktreeID, let branch, let worktreePath):
        state.worktreePaths[worktreeID] = worktreePath
        if let loadedAt = state.snapshotLoadedAt[worktreeID],
          now.timeIntervalSince(loadedAt) < Self.snapshotFreshness,
          state.snapshots[worktreeID] != nil
        {
          return .none  // cached
        }
        if state.loading.contains(worktreeID) { return .none }  // already in flight
        state.loading.insert(worktreeID)
        return snapshotFetchEffect(worktreeID: worktreeID, branch: branch, worktreePath: worktreePath)

      case .refreshRequested(let worktreeID, let branch, let worktreePath):
        state.worktreePaths[worktreeID] = worktreePath
        state.snapshotLoadedAt[worktreeID] = nil  // force re-probe
        state.loading.insert(worktreeID)
        return snapshotFetchEffect(worktreeID: worktreeID, branch: branch, worktreePath: worktreePath)

      case .snapshotLoaded(let worktreeID, .success(let snapshot)):
        state.loading.remove(worktreeID)
        state.snapshotLoadedAt[worktreeID] = now
        state.lastError[worktreeID] = nil
        if let snapshot {
          state.snapshots[worktreeID] = snapshot
          // Prefetch checks so the sidebar row icon's CI-rollup overlay can paint on the
          // first render, not only after the popover is opened. `worktreePaths` is seeded
          // by every code path that could produce a snapshot (visibility, refresh,
          // post-mutation), so the lookup is always populated here.
          if let worktreePath = state.worktreePaths[worktreeID] {
            return checksFetchEffect(prNumber: snapshot.number, worktreePath: worktreePath)
          }
        } else {
          state.snapshots[worktreeID] = nil
        }
        return .none

      case .snapshotLoaded(let worktreeID, .failure(let error)):
        state.loading.remove(worktreeID)
        state.snapshotLoadedAt[worktreeID] = now
        let ghError = (error as? GitHubError) ?? .other(String(describing: error))
        state.lastError[worktreeID] = ghError
        return .none

      case .checksLoaded(let prNumber, .success(let checks)):
        state.checks[prNumber] = checks
        return .none

      case .checksLoaded(let prNumber, .failure):
        // Keep any previously-loaded checks on error; the popover surfaces the error via
        // lastError at the Worktree level instead.
        state.checks[prNumber] = state.checks[prNumber] ?? []
        return .none

      case .workflowRunLoaded(let prNumber, .success(let run)):
        if let run {
          state.latestWorkflowRuns[prNumber] = run
        }
        return .none

      case .workflowRunLoaded:
        return .none  // swallow error — rerun button just stays disabled

      // MARK: - popover

      case .presentPopover(let worktreeID, let worktreePath):
        state.popoverTarget = worktreeID
        state.worktreePaths[worktreeID] = worktreePath
        // Kick off checks + latest workflow run on popover open. Uses the cached snapshot
        // to know the PR number and branch.
        guard let snapshot = state.snapshots[worktreeID] else { return .none }
        return .merge(
          checksFetchEffect(prNumber: snapshot.number, worktreePath: worktreePath),
          workflowRunFetchEffect(
            prNumber: snapshot.number, branch: snapshot.headRefName, worktreePath: worktreePath
          )
        )

      case .dismissPopover:
        state.popoverTarget = nil
        return .none

      // MARK: - merge

      case .mergeRequested(let worktreeID, let prNumber, let strategy, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }  // already running
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.merge(prNumber, strategy, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.mergeCompleted(worktreeID, prNumber: prNumber, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .mergeCompleted(let worktreeID, _, .success):
        state.mutating.remove(worktreeID)
        // Delegate pullRequestMerged so RootFeature can trigger the post-merge action,
        // then kick off a refresh so the badge flips to merged on its own.
        let refresh = postMutationRefresh(worktreeID: worktreeID, state: &state)
        if let snapshot = state.snapshots[worktreeID] {
          return .merge(.send(.delegate(.pullRequestMerged(worktreeID, snapshot: snapshot))), refresh)
        }
        return refresh

      case .mergeCompleted(let worktreeID, _, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      // MARK: - close

      case .closeRequested(let worktreeID, let prNumber, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.close(prNumber, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.closeCompleted(worktreeID, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .closeCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case .closeCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - markReady

      case .markReadyRequested(let worktreeID, let prNumber, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.markReady(prNumber, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.markReadyCompleted(worktreeID, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .markReadyCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case .markReadyCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - rerunFailedJobs

      case .rerunFailedJobsRequested(let worktreeID, let runID, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.rerunFailedJobs(runID, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.rerunFailedJobsCompleted(worktreeID, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .rerunFailedJobsCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case .rerunFailedJobsCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - delegate

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Effect builders

  private func probeAvailabilityEffect() -> Effect<Action> {
    .run { send in
      let result = await gitHub.availability()
      await send(.availabilityProbed(result, probedAt: now))
    }
    .cancellable(id: CancelID.availabilityRefresh, cancelInFlight: true)
  }

  private func snapshotFetchEffect(
    worktreeID: WorktreeID, branch: String, worktreePath: URL
  ) -> Effect<Action> {
    .run { send in
      let result = await TaskResult<PullRequestSnapshot?> {
        try await gitHub.pullRequest(branch, worktreePath)
      }
      await send(.snapshotLoaded(worktreeID, result))
    }
    .cancellable(id: CancelID.snapshot(worktreeID), cancelInFlight: true)
  }

  private func checksFetchEffect(prNumber: Int, worktreePath: URL) -> Effect<Action> {
    .run { send in
      let result = await TaskResult<[CheckResult]> {
        try await gitHub.checks(prNumber, worktreePath)
      }
      await send(.checksLoaded(prNumber: prNumber, result))
    }
    .cancellable(id: CancelID.checks(prNumber: prNumber), cancelInFlight: true)
  }

  private func workflowRunFetchEffect(
    prNumber: Int, branch: String, worktreePath: URL
  ) -> Effect<Action> {
    .run { send in
      let result = await TaskResult<WorkflowRun?> {
        try await gitHub.latestWorkflowRun(branch, worktreePath)
      }
      await send(.workflowRunLoaded(prNumber: prNumber, result))
    }
    .cancellable(id: CancelID.workflowRun(prNumber: prNumber), cancelInFlight: true)
  }

  /// Re-dispatches a snapshot fetch for a Worktree so a recently-completed mutation
  /// (merge / close / markReady / rerun) is reflected by the next UI render. Looks up
  /// the cached branch + path; if either is missing, returns `.none` (the next
  /// `worktreeBecameVisible` re-dispatch will cover it).
  private func postMutationRefresh(
    worktreeID: WorktreeID, state: inout State
  ) -> Effect<Action> {
    guard let branch = state.snapshots[worktreeID]?.headRefName,
      let worktreePath = state.worktreePaths[worktreeID]
    else { return .none }
    state.snapshotLoadedAt[worktreeID] = nil
    state.loading.insert(worktreeID)
    return snapshotFetchEffect(worktreeID: worktreeID, branch: branch, worktreePath: worktreePath)
  }

}

extension TaskResult where Success == GitHubFeature.Action.VoidSuccess {
  /// Convenience to keep the reducer's action construction terse.
  static var successVoid: TaskResult<GitHubFeature.Action.VoidSuccess> {
    .success(.init())
  }
}
