import Foundation
import TouchCodeCore

/// Argv builder for every `gh` invocation the GitHub integration issues. Each static
/// function returns the complete argument vector (without the `gh` executable path)
/// together with the exit codes that are treated as *success* by the calling service.
///
/// `gh` exits non-zero for a wide range of conditions — "no PR found", "not authenticated",
/// network failure, etc. The caller decides which of those to treat as a fatal error and
/// which to translate into a richer domain result (`.notAPullRequest`, `.notAuthenticated`,
/// etc.). `expectedExitCodes` names the codes that reach the happy-path parsing; anything
/// else triggers `LiveGitHubService`'s stderr-sniffing error-translation branch.
///
/// Tests lock every argv list — these are the exact strings sent to a long-lived external
/// tool, and a silent drift (flag position, missing `--json` field) can mask real bugs.
/// Precedent: exec-plan 0005 DEC-19 — a `-w` placement test that didn't reach argv masked
/// a flag-vs-pathspec bug.
nonisolated enum GhCommand {
  /// `gh auth status --json hosts`. Exit 0 → logged in (parse hosts); exit 1 → not logged in.
  static func authStatus() -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["auth", "status", "--json", "hosts"], [0, 1])
  }

  /// `gh pr view <branch> --json <fields>`. Exit 0 → PR exists; exit 1 → no PR for this
  /// branch (parsed as `.notAPullRequest` by the caller).
  static func pullRequestView(branch: String) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    let fields = [
      "number", "title", "state", "isDraft", "headRefName",
      "author", "additions", "deletions", "commits",
      "mergeable", "url", "updatedAt",
    ].joined(separator: ",")
    return (["pr", "view", branch, "--json", fields], [0, 1])
  }

  /// `gh pr checks <number> --json <fields>`. Exit 0 → checks exist; other codes are
  /// treated as fatal by the caller. `gh` collapses status + conclusion into a single
  /// `state` field — the parser splits them back out when building `CheckResult`.
  static func pullRequestChecks(number: Int) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    let fields = ["name", "state", "bucket", "startedAt", "completedAt", "link", "workflow"]
      .joined(separator: ",")
    return (["pr", "checks", String(number), "--json", fields], [0])
  }

  /// `gh run list --branch <branch> --limit 1 --json <fields>`. Returns the latest
  /// workflow run for the branch. Empty array → no runs yet (caller returns nil).
  static func runListLatest(branch: String) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    let fields = [
      "databaseId", "name", "status", "conclusion",
      "headBranch", "headSha", "number", "updatedAt", "url",
    ].joined(separator: ",")
    return (
      ["run", "list", "--branch", branch, "--limit", "1", "--json", fields],
      [0]
    )
  }

  /// `gh pr merge <number> <flag>`. `flag` is `MergeStrategy.cliFlag`.
  static func pullRequestMerge(
    number: Int,
    strategy: MergeStrategy
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "merge", String(number), strategy.cliFlag], [0])
  }

  /// `gh pr close <number>`.
  static func pullRequestClose(number: Int) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "close", String(number)], [0])
  }

  /// `gh pr ready <number>`. Promotes a draft PR to ready-for-review.
  static func pullRequestReady(number: Int) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "ready", String(number)], [0])
  }

  /// `gh run rerun <runID> --failed`. One-shot: re-runs every failed job in the run.
  /// Per exec-plan 0012 DEC-3 there is no per-job selection in v1.
  static func runRerunFailed(runID: Int64) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["run", "rerun", String(runID), "--failed"], [0])
  }
}
