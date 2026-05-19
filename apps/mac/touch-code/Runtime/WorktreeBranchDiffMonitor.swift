import ComposableArchitecture
import Foundation
import TouchCodeCore
import os.log

/// Cached per-Worktree "branch vs base" diff-stats observer. The sidebar
/// reads `stats[worktreeID]` to render a `+N −M` chip even on worktrees that
/// don't yet have a matched PR.
///
/// - Fetches run lazily: the sidebar row's `.task(id:)` calls
///   `refresh(worktreeID:path:)` on appearance, branch change, or path change.
///   A 30 s freshness window mirrors `WorktreeStatusMonitor` so the two
///   refresh on the same cadence.
/// - Failures are silent: a missing `origin/HEAD`, a shallow clone, or a
///   detached HEAD returns the last cached value (if any) and leaves
///   `stats[id]` unchanged. A stale chip is less harmful than a wrong one.
/// - `nil` value means "no stats applicable" — either HEAD is on base or no
///   base could be resolved. The view treats nil the same as a missing entry.
@Observable
@MainActor
final class WorktreeBranchDiffMonitor {
  /// Latest `BranchDiffStats` per worktree. `nil` value = "fetched, no stats
  /// applicable" (HEAD == base or base unresolvable); missing key = "not yet
  /// fetched". The view treats both as "render nothing".
  private(set) var stats: [WorktreeID: BranchDiffStats?] = [:]

  @ObservationIgnored
  private var lastFetchedAt: [WorktreeID: Date] = [:]

  @ObservationIgnored
  private var inFlight: Set<WorktreeID> = []

  @ObservationIgnored
  private let fetch: @Sendable (URL) async throws -> BranchDiffStats?

  @ObservationIgnored
  private static let freshness: TimeInterval = 30

  private static let logger = Logger(subsystem: "com.touch-code.sidebar", category: "branchDiff")

  init(fetch: @escaping @Sendable (URL) async throws -> BranchDiffStats?) {
    self.fetch = fetch
  }

  static func live() -> WorktreeBranchDiffMonitor {
    let client = GitServiceClient.live()
    return WorktreeBranchDiffMonitor(fetch: client.branchDiffStats)
  }

  /// Refreshes the diff stats for the given Worktree, honouring the 30 s
  /// freshness window. Re-entrant calls while a fetch is in flight are
  /// deduped. Safe to call on every `.task(id:)` — the view is in charge of
  /// re-invoking when the worktree path or branch changes.
  func refresh(worktreeID: WorktreeID, path: URL) async {
    if inFlight.contains(worktreeID) { return }
    if let fetchedAt = lastFetchedAt[worktreeID],
      Date().timeIntervalSince(fetchedAt) < Self.freshness
    {
      return
    }
    inFlight.insert(worktreeID)
    defer { inFlight.remove(worktreeID) }
    do {
      let result = try await fetch(path)
      stats[worktreeID] = result
      lastFetchedAt[worktreeID] = Date()
    } catch {
      Self.logger.debug(
        "branch-diff fetch failed for \(path.path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)"
      )
    }
  }
}
