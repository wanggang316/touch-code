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
  /// `(repoURL, cursor) -> LogPage`.
  var log: @Sendable (URL, LogPage.Cursor) async throws -> LogPage
  /// `(repoURL, ignoreWhitespace) -> UnifiedDiff`. `ignoreWhitespace=true` passes `-w`.
  var workingTreeDiff: @Sendable (URL, Bool) async throws -> UnifiedDiff
  var stagedDiff: @Sendable (URL, Bool) async throws -> UnifiedDiff
  /// `(repoURL, sha, ignoreWhitespace) -> UnifiedDiff`.
  var commitDiff: @Sendable (URL, String, Bool) async throws -> UnifiedDiff
  // `status` intentionally absent from the client: M4a doesn't consume it. The service
  // protocol keeps `status(at:)` for the C7 design's header-badges future; add the closure
  // here alongside the UI surface that reads it (not before). See 0005 M3 review item 2.
}

extension GitServiceClient {
  /// Constructs a client that forwards to a concrete `GitService`.
  static func live(service: any GitService = Git.makeService()) -> GitServiceClient {
    GitServiceClient(
      log: { url, cursor in try await service.log(at: url, page: cursor) },
      workingTreeDiff: { url, ignoreWhitespace in
        try await service.workingTreeDiff(at: url, ignoreWhitespace: ignoreWhitespace)
      },
      stagedDiff: { url, ignoreWhitespace in
        try await service.stagedDiff(at: url, ignoreWhitespace: ignoreWhitespace)
      },
      commitDiff: { url, sha, ignoreWhitespace in
        try await service.commitDiff(at: url, sha: sha, ignoreWhitespace: ignoreWhitespace)
      }
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
    )
  )
}

extension DependencyValues {
  var gitService: GitServiceClient {
    get { self[GitServiceClient.self] }
    set { self[GitServiceClient.self] = newValue }
  }
}
