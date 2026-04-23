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

    /// Latest workflow run keyed by PR number. Seeds the "Rerun failed jobs" action.
    /// Open Question 4 in the design doc tracks whether this separate fetch can be
    /// collapsed into the batched query (extract runID from `detailsUrl`); for now it
    /// remains a popover-time single-call lookup.
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

    // MARK: - v2 project-batched fetch (0013 M4)

    /// Cached batched result per Project. Keyed by ProjectID because the batched
    /// GraphQL query targets a single repository. The whole map is rebuilt lazily on
    /// Project activation / invalidation events.
    var snapshotsByProject: [ProjectID: BatchedPullRequests] = [:]

    /// Set of Projects with an active `batchPullRequests` subprocess in flight. Used by
    /// the re-entrancy guard: a second `projectRefreshRequested` for a Project already
    /// in this set is queued, not dispatched.
    var inFlightFetchProjects: Set<ProjectID> = []

    /// Projects that requested a refresh while a prior fetch was in flight. Drained
    /// into a new fetch when the in-flight fetch completes.
    var queuedRefreshByProject: Set<ProjectID> = []

    /// Per-Project last-seen error from the batched fetch. Cleared on next success.
    /// Displayed in the sidebar's Settings → GitHub banner, not per-row.
    var lastErrorByProject: [ProjectID: GitHubError] = [:]

    /// Last-known gitRoot per Project. Stashed so the queued-refresh drain + the
    /// delayed post-mutation refresh can re-issue a fetch without the caller re-passing
    /// the gitRoot. Cleared when the Project is removed from the catalog (not modelled
    /// yet — see Risk R4 in the design doc).
    var projectGitRoots: [ProjectID: URL] = [:]

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

    // MARK: - v2 project-batched fetch (0013 M4)

    /// Project gained focus or was freshly activated. If no cached snapshot exists (or
    /// the cached branch set does not match the current Worktree list), dispatch a full
    /// refresh. Payload carries the data the batched fetcher needs so the reducer does
    /// not read `HierarchyManager` synchronously inside an effect.
    case projectActivated(
      ProjectID,
      gitRoot: URL,
      worktreeBranches: [WorktreeBranchPair]
    )

    /// Force a fresh `gh api graphql` for the Project, respecting the in-flight + queued
    /// re-entrancy model. Used by manual refresh + post-write delayed refresh.
    case projectRefreshRequested(
      ProjectID,
      gitRoot: URL,
      worktreeBranches: [WorktreeBranchPair]
    )

    /// Result of a single `batchPullRequests` call. On success, the reducer stores the
    /// batched result under the Project and projects each branch's snapshot into the
    /// per-Worktree `state.snapshots` dict so v1 consumers see the refreshed data.
    case projectBatchLoaded(
      ProjectID,
      worktreeBranches: [WorktreeBranchPair],
      TaskResult<BatchedPullRequests>
    )

    /// Emitted by the sidebar when a terminal-initiated `git checkout` changes a
    /// Worktree's branch. Invalidates the Project's cache and kicks a refresh. The
    /// `WorktreeBranchWatcher` responsible for dispatching this lives in M7 and may
    /// ship empty-handed in v2.0.
    case worktreeBranchChanged(
      WorktreeID,
      newBranch: String,
      projectID: ProjectID,
      gitRoot: URL,
      worktreeBranches: [WorktreeBranchPair]
    )

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

    /// `(worktreeID, branch)` pair carried by the v2 project-batched actions. Passed
    /// into the reducer so it does not need to read `HierarchyManager` from inside an
    /// effect (which would require bridging `@MainActor` and the `@Sendable` effect
    /// boundary). The dispatcher — `RootFeature` observing `selectionChanges` —
    /// constructs the list from the current catalog once per dispatch.
    nonisolated struct WorktreeBranchPair: Equatable, Sendable, Hashable {
      let worktreeID: WorktreeID
      let branch: String
      init(worktreeID: WorktreeID, branch: String) {
        self.worktreeID = worktreeID
        self.branch = branch
      }
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case availabilityRefresh
    case snapshot(WorktreeID)
    case workflowRun(prNumber: Int)
    /// One-cancellation-slot for all mutations on a Worktree so a second click while an
    /// operation is in flight cancels the prior run rather than racing it.
    case mutation(WorktreeID)
    /// Per-Project batched fetch (0013 M4). Re-dispatching `projectRefreshRequested`
    /// for an in-flight Project cancels the prior fetch and replaces it.
    case projectFetch(ProjectID)
    /// Delayed post-mutation refresh (0013 M4 — merge / close / markReady / rerun all
    /// schedule this 2 s after a successful write).
    case delayedProjectRefresh(ProjectID)
    /// `gh` availability recovery heartbeat — retries every 15 s after an outage.
    case availabilityRecovery
  }

  /// Availability result is treated as fresh for 30 s; subsequent `onAppear` / visibility
  /// dispatches within the window skip the probe.
  static let availabilityFreshness: TimeInterval = 30

  /// Snapshot freshness. Under this, a worktreeBecameVisible is a no-op (already cached).
  static let snapshotFreshness: TimeInterval = 30

  @Dependency(GitHubClient.self) var gitHub
  /// Resolves `(host, owner, repo)` for batched fetches via `git remote get-url origin`.
  @Dependency(GitServiceClient.self) var gitServiceClient
  @Dependency(\.date.now) var now

  /// Back-compat alias so existing `gitHubClient` usages compile unchanged. The
  /// reducer body was written with `gitHub`; the M4 additions use `gitHubClient` for
  /// clarity inside the new fetch effect builder.
  private var gitHubClient: GitHubClient { gitHub }

  nonisolated static let logger = Logger(subsystem: "com.touch-code.github", category: "feature")

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
        // 0013 M5: the v2 batched path carries checkRollup inline on the snapshot, so the
        // per-Worktree prefetch of `gh pr checks` that used to fire here is gone. Views
        // read `snapshot.checkRollup` directly. v1-path single-branch refreshes (still
        // reachable via postMutationRefresh) now fill `snapshot.checkRollup` with [] —
        // acceptable during M5–M6 because the next batched refresh will repopulate it.
        if let snapshot {
          state.snapshots[worktreeID] = snapshot
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
        // Checks travel on the snapshot now (0013 M5) — the only thing popover-open
        // still needs to fetch is the latest workflow run, which seeds the "Rerun
        // failed jobs" button with a runID. Dropping it is tracked as Open Question
        // 4 in the design doc (parse runID from `checkRollup[].detailsURL`).
        guard let snapshot = state.snapshots[worktreeID] else { return .none }
        return workflowRunFetchEffect(
          prNumber: snapshot.number, branch: snapshot.headRefName, worktreePath: worktreePath
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

      // MARK: - v2 project-batched fetch (0013 M4)

      case let .projectActivated(projectID, gitRoot, pairs):
        Self.logger.info(
          "projectActivated project=\(projectID.raw.uuidString, privacy: .public) branches=\(pairs.count, privacy: .public) gitRoot=\(gitRoot.path, privacy: .private(mask: .hash))"
        )
        if state.snapshotsByProject[projectID] != nil,
          Self.branchSetsMatch(cached: state.snapshotsByProject[projectID], current: pairs) {
          Self.logger.info("projectActivated cache-hit, skipping fetch")
          return .none
        }
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      case let .projectRefreshRequested(projectID, gitRoot, pairs):
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      case .projectBatchLoaded(let projectID, let pairs, .success(let batched)):
        Self.logger.info(
          "projectBatchLoaded success project=\(projectID.raw.uuidString, privacy: .public) branches=\(batched.byBranch.count, privacy: .public)/\(pairs.count, privacy: .public)"
        )
        state.inFlightFetchProjects.remove(projectID)
        state.lastErrorByProject[projectID] = nil
        state.snapshotsByProject[projectID] = batched
        // Project into per-Worktree `snapshots` so v1 view code keeps rendering
        // consistent data while M5 migrates views to read from `snapshotsByProject`.
        // Branches absent from `batched.byBranch` are dropped from `snapshots` so a
        // PR that was closed between fetches doesn't linger as stale.
        for pair in pairs {
          if let snap = batched.byBranch[pair.branch] {
            state.snapshots[pair.worktreeID] = snap
            state.snapshotLoadedAt[pair.worktreeID] = now
            state.lastError[pair.worktreeID] = nil
          } else {
            state.snapshots[pair.worktreeID] = nil
          }
        }
        // Drain any queued refresh for this Project.
        if state.queuedRefreshByProject.remove(projectID) != nil,
          let gitRoot = state.projectGitRoots[projectID] {
          return .send(
            .projectRefreshRequested(projectID, gitRoot: gitRoot, worktreeBranches: pairs)
          )
        }
        return .none

      case .projectBatchLoaded(let projectID, _, .failure(let error)):
        Self.logger.error(
          "projectBatchLoaded failure project=\(projectID.raw.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
        state.inFlightFetchProjects.remove(projectID)
        state.lastErrorByProject[projectID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case let .worktreeBranchChanged(_, _, projectID, gitRoot, pairs):
        // Branch change invalidates whatever was cached for the Project and kicks a
        // fresh batched fetch. The Worktree's own per-row snapshot is not cleared here
        // — waiting ~500ms for the batched result to arrive avoids a visible flicker.
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      // MARK: - delegate

      case .delegate:
        return .none
      }
    }
  }

  /// Kicks a batched fetch for the Project, honouring the in-flight guard. If another
  /// fetch is already running for the same Project, records a queue flag so the in-flight
  /// completion can dispatch a follow-up. Otherwise starts the subprocess chain, tagged
  /// with `CancelID.projectFetch(projectID)` so a subsequent call cancels the prior one.
  private func enqueueProjectFetch(
    projectID: ProjectID,
    gitRoot: URL,
    pairs: [Action.WorktreeBranchPair],
    state: inout State
  ) -> Effect<Action> {
    state.projectGitRoots[projectID] = gitRoot
    if state.inFlightFetchProjects.contains(projectID) {
      state.queuedRefreshByProject.insert(projectID)
      return .none
    }
    state.inFlightFetchProjects.insert(projectID)
    let fetchedAt = now
    Self.logger.info(
      "enqueueProjectFetch project=\(projectID.raw.uuidString, privacy: .public) pairs=\(pairs.count, privacy: .public)"
    )
    return .run { [client = gitHubClient, gitService = gitServiceClient] send in
      let result = await TaskResult<BatchedPullRequests> {
        let remote: RemoteInfo
        do {
          remote = try await gitService.remoteInfo(gitRoot)
        } catch {
          Self.logger.error(
            "remoteInfo failed: \(String(describing: error), privacy: .public)"
          )
          throw GitHubError.remoteInfoUnavailable
        }
        Self.logger.info(
          "remoteInfo resolved host=\(remote.host, privacy: .public) owner=\(remote.owner, privacy: .public) repo=\(remote.repo, privacy: .public)"
        )
        let branches = pairs.map(\.branch)
        let seen = Set(branches)
        if branches.isEmpty {
          return BatchedPullRequests(
            host: remote.host, owner: remote.owner, repo: remote.repo,
            byBranch: [:], seenBranches: seen, fetchedAt: fetchedAt
          )
        }
        let byBranch = try await client.batchPullRequests(
          remote.host, remote.owner, remote.repo, branches
        )
        return BatchedPullRequests(
          host: remote.host, owner: remote.owner, repo: remote.repo,
          byBranch: byBranch, seenBranches: seen, fetchedAt: fetchedAt
        )
      }
      await send(.projectBatchLoaded(projectID, worktreeBranches: pairs, result))
    }
    .cancellable(id: CancelID.projectFetch(projectID), cancelInFlight: true)
  }

  /// Returns true iff the cached snapshot's branch set exactly matches the current
  /// Worktree branch list. Used to skip redundant refreshes on repeat activations of
  /// the same Project (no new Worktree, no branch change).
  private static func branchSetsMatch(
    cached: BatchedPullRequests?,
    current: [Action.WorktreeBranchPair]
  ) -> Bool {
    guard let cached else { return false }
    // Branches that had a PR are in byBranch; branches that did not are absent. For
    // cache-validity purposes we consider the full pair list; if ANY Worktree exists
    // that is not represented by cached.byBranch presence-or-absence, refetch.
    // Conservative check: compare the current list's branches against
    // cached.byBranch.keys plus those we've previously decided have no PR.
    // v2.0 keeps this simple: trigger refresh if the current branch *set* differs from
    // a cached "seen set" of branches. We store the cached seen set on `BatchedPullRequests`.
    let currentBranches = Set(current.map(\.branch))
    return cached.seenBranches == currentBranches
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
