import Foundation
import TouchCodeCore

/// Process-backed `GitService`. Builds argv via `GitCommand`, runs through the pluggable
/// `CommandRunner` seam (live implementation wraps `Foundation.Process`), applies
/// `GitProcessEnv` stripping, and enforces the 16 MiB output cap + 10 s wall-clock timeout.
///
/// Correctness notes (fixes from 0005 M2 review):
/// - `gitExecutable` defaults to `/usr/bin/git` directly, not `/usr/bin/env`. This keeps the
///   env-whitelist guarantee (`PATH` exposure is then irrelevant to which git runs).
/// - `.notARepo` is detected via `rev-parse --is-inside-work-tree` at the edge, not by
///   substring-matching stderr. Stderr matching is retained only as a narrow fallback for
///   paths where the pre-check races with the Worktree being removed.
/// - Invalid commit SHAs are rejected before the subprocess spawns.
nonisolated final class LiveGitService: GitService {
  static let maxOutputBytes = 16 * 1024 * 1024      // 16 MiB
  static let defaultTimeout: Duration = .seconds(10)

  let gitExecutable: URL
  let runner: any CommandRunner

  init(
    gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
    runner: any CommandRunner = FoundationCommandRunner()
  ) {
    self.gitExecutable = gitExecutable
    self.runner = runner
  }

  // MARK: - GitService

  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage {
    try await ensureIsRepo(at: path)
    let probeLimit = max(1, page.limit + 1)
    let args = GitCommand.log(limit: probeLimit, skip: page.offset)
    let out = try await run(arguments: args, cwd: path)
    var commits = try GitOutputParser.parseLog(out)
    let hasMore = commits.count > page.limit
    if hasMore { commits.removeLast() }
    return LogPage(cursor: page, commits: commits, hasMore: hasMore)
  }

  func workingTreeDiff(at path: URL) async throws -> UnifiedDiff {
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.diff(kind: .workingTree), cwd: path)
    return try DiffParser.parse(out, scope: .working)
  }

  func stagedDiff(at path: URL) async throws -> UnifiedDiff {
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.diff(kind: .staged), cwd: path)
    return try DiffParser.parse(out, scope: .staged)
  }

  func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff {
    guard GitShaValidator.isValid(sha) else {
      throw GitError.invalidInput("not a git SHA: '\(sha)'")
    }
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.diff(kind: .commit(sha: sha)), cwd: path)
    return try DiffParser.parse(out, scope: .commit(sha: sha))
  }

  func status(at path: URL) async throws -> WorkingTreeStatus {
    try await ensureIsRepo(at: path)
    let out = try await run(arguments: GitCommand.status(), cwd: path)
    return try GitOutputParser.parseStatus(out)
  }

  // MARK: - Edge checks

  /// Runs `git rev-parse --is-inside-work-tree` and throws `.notARepo` on failure. This is the
  /// authoritative check — no stderr substring matching. Idempotent; cheap (< 10 ms on local).
  private func ensureIsRepo(at path: URL) async throws {
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: GitCommand.revParseIsInsideWorkTree(),
      env: GitProcessEnv.build(),
      cwd: path,
      timeout: Self.defaultTimeout,
      maxOutputBytes: 1024
    )
    switch outcome {
    case .exited(let code, _, _, _):
      if code != 0 { throw GitError.notARepo }
    case .timedOut:
      throw GitError.timedOut
    case .spawnFailed(let reason):
      if reason.contains("binary not found") { throw GitError.gitMissing }
      throw GitError.unparsable(context: "rev-parse spawn failed: \(reason)")
    }
  }

  // MARK: - Runner invocation

  /// Runs `gitExecutable` with `arguments`, translating `CommandOutcome` to domain error or
  /// success. Applies env whitelist + 16 MiB cap + 10 s timeout.
  private func run(arguments: [String], cwd: URL) async throws -> Data {
    let outcome = await runner.run(
      executable: gitExecutable,
      arguments: arguments,
      env: GitProcessEnv.build(),
      cwd: cwd,
      timeout: Self.defaultTimeout,
      maxOutputBytes: Self.maxOutputBytes
    )
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow { throw GitError.outputTooLarge }
      if code != 0 {
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        // Narrow fallback: the pre-check passed (rev-parse succeeded) but the subsequent
        // command raced with the worktree disappearing. Canonical git stderr phrases only.
        if stderrText.contains("fatal: not a git repository")
          || stderrText.contains("fatal: bad revision")
          || stderrText.contains("fatal: Not a valid object name") {
          throw GitError.notARepo
        }
        throw GitError.exec(code: code, stderr: stderrText)
      }
      return stdout
    case .timedOut:
      throw GitError.timedOut
    case .spawnFailed(let reason):
      if reason.contains("binary not found") { throw GitError.gitMissing }
      throw GitError.unparsable(context: "spawn failed: \(reason)")
    }
  }
}
