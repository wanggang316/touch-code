import Foundation
import TouchCodeCore

/// Read-only Git service. Invoked by `GitViewerFeature` (M3) and, in future, by the `git.*` IPC
/// namespace. All operations are pure with respect to the file system — they never write.
///
/// `nonisolated` so conformers (including `LiveGitService`) can freely be `Sendable` without
/// fighting the app target's `@MainActor` default.
public nonisolated protocol GitService: Sendable {
  /// Commit log for the repository at `path`, paginated by `page`.
  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage

  /// `git diff` — working tree vs. index. `ignoreWhitespace=true` passes `-w`.
  func workingTreeDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff

  /// `git diff --cached` — index vs. HEAD. `ignoreWhitespace=true` passes `-w`.
  func stagedDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff

  /// `git show <sha>` rendered as a unified diff. `ignoreWhitespace=true` passes `-w`.
  func commitDiff(at path: URL, sha: String, ignoreWhitespace: Bool) async throws -> UnifiedDiff

  /// `git status --porcelain=v1 -z`.
  func status(at path: URL) async throws -> WorkingTreeStatus

  /// `git remote get-url origin` parsed into host / owner / repo. Used by the GitHub
  /// integration's batched PR fetcher to target the right `gh api graphql --hostname` host
  /// and `(owner, repo)` variables. Throws `GitError.malformedRemoteURL` when the remote
  /// URL shape is not recognised.
  func remoteInfo(at path: URL) async throws -> RemoteInfo
}

extension GitService {
  /// Convenience overloads: `ignoreWhitespace` defaults to false. Keeps old call sites
  /// (integration tests, future IPC bridge) readable.
  public func workingTreeDiff(at path: URL) async throws -> UnifiedDiff {
    try await workingTreeDiff(at: path, ignoreWhitespace: false)
  }
  public func stagedDiff(at path: URL) async throws -> UnifiedDiff {
    try await stagedDiff(at: path, ignoreWhitespace: false)
  }
  public func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff {
    try await commitDiff(at: path, sha: sha, ignoreWhitespace: false)
  }
}
