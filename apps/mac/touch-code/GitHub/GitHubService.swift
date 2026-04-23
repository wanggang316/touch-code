import Foundation
import TouchCodeCore

/// Stateless protocol over the `gh` CLI surface that the GitHub integration needs.
///
/// Every method passes the Worktree's absolute path as the subprocess `cwd` so `gh`
/// resolves the correct repository + remote automatically. User input (branch names,
/// PR numbers, commit SHAs) is always an argv element — never interpolated into a
/// shell. Tests inject `any GitHubService` via `GitHubClient` (TCA DependencyKey,
/// lands in M3).
///
/// Methods that read return either a value, `nil` (for "nothing to report" like "no
/// PR for this branch"), or throw a `GitHubError`. Methods that mutate return Void on
/// success and throw on any non-zero exit.
nonisolated protocol GitHubService: Sendable {
  /// Probes whether gh is installed and logged in. Never throws — the failure is the
  /// `.unavailable` case of the returned enum. Cached for 30 s by the feature reducer.
  func availability() async -> GitHubAvailability

  /// Returns the PR associated with the given branch at the given worktree, or `nil`
  /// when the branch has no PR. Throws on mechanical failures (gh missing, timeout,
  /// decode error, auth error).
  func pullRequest(branch: String, worktreePath: URL) async throws -> PullRequestSnapshot?

  /// Returns the list of checks for the PR number. Empty list when no CI exists.
  func checks(number: Int, worktreePath: URL) async throws -> [CheckResult]

  /// Returns the most-recent workflow run for the branch, or `nil` when no run exists.
  func latestWorkflowRun(branch: String, worktreePath: URL) async throws -> WorkflowRun?

  /// Merges the PR with the given strategy. Throws `.mergeConflict` when the PR is
  /// not cleanly mergeable.
  func merge(number: Int, strategy: MergeStrategy, worktreePath: URL) async throws

  /// Closes the PR without merging.
  func close(number: Int, worktreePath: URL) async throws

  /// Promotes a draft PR to ready-for-review.
  func markReady(number: Int, worktreePath: URL) async throws

  /// Re-runs every failed job in the given workflow run (one `gh run rerun --failed` call).
  func rerunFailedJobs(runID: Int64, worktreePath: URL) async throws
}

extension GitHub {
  /// Default factory. Returns a `LiveGitHubService` wired to the shared
  /// `GhExecutableResolver` and a live `FoundationCommandRunner`. Internal (not public)
  /// so the concrete `GitHubService` protocol stays app-local — v2 IPC surface would
  /// either re-export or define its own wire protocol.
  static func makeService() -> any GitHubService {
    LiveGitHubService()
  }
}
