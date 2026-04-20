import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency-injection bridge over the `GitService` protocol from
/// `touch-code/Git/`. Each closure mirrors one protocol method. Mirrors
/// `HierarchyClient` / `TerminalClient` in shape so features use a
/// consistent pattern.
///
/// Not `@MainActor`: `GitService` is nonisolated and conforms to `Sendable`.
/// Closures are `@Sendable` async — safe to call from any reducer effect.
nonisolated struct GitServiceClient: Sendable {
  var log: @Sendable (URL, LogPage.Cursor) async throws -> LogPage
  var workingTreeDiff: @Sendable (URL) async throws -> UnifiedDiff
  var stagedDiff: @Sendable (URL) async throws -> UnifiedDiff
  var commitDiff: @Sendable (URL, String) async throws -> UnifiedDiff
  var status: @Sendable (URL) async throws -> WorkingTreeStatus
}

extension GitServiceClient {
  /// Constructs a client that forwards to a concrete `GitService`.
  static func live(service: any GitService = Git.makeService()) -> GitServiceClient {
    GitServiceClient(
      log: { url, cursor in try await service.log(at: url, page: cursor) },
      workingTreeDiff: { url in try await service.workingTreeDiff(at: url) },
      stagedDiff: { url in try await service.stagedDiff(at: url) },
      commitDiff: { url, sha in try await service.commitDiff(at: url, sha: sha) },
      status: { url in try await service.status(at: url) }
    )
  }
}

extension GitServiceClient: DependencyKey {
  static let liveValue: GitServiceClient = .live()

  static let testValue: GitServiceClient = GitServiceClient(
    log: unimplemented(
      "GitServiceClient.log",
      placeholder: LogPage(cursor: .init(offset: 0, limit: 0), commits: [], hasMore: false)
    ),
    workingTreeDiff: unimplemented(
      "GitServiceClient.workingTreeDiff",
      placeholder: UnifiedDiff(scope: .working, files: [])
    ),
    stagedDiff: unimplemented(
      "GitServiceClient.stagedDiff",
      placeholder: UnifiedDiff(scope: .staged, files: [])
    ),
    commitDiff: unimplemented(
      "GitServiceClient.commitDiff",
      placeholder: UnifiedDiff(scope: .commit(sha: ""), files: [])
    ),
    status: unimplemented(
      "GitServiceClient.status",
      placeholder: WorkingTreeStatus(entries: [])
    )
  )
}

extension DependencyValues {
  var gitService: GitServiceClient {
    get { self[GitServiceClient.self] }
    set { self[GitServiceClient.self] = newValue }
  }
}
