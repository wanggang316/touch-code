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

  /// `git diff` — working tree vs. index.
  func workingTreeDiff(at path: URL) async throws -> UnifiedDiff

  /// `git diff --cached` — index vs. HEAD.
  func stagedDiff(at path: URL) async throws -> UnifiedDiff

  /// `git show <sha>` rendered as a unified diff.
  func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff

  /// `git status --porcelain=v1 -z`.
  func status(at path: URL) async throws -> WorkingTreeStatus
}
