import Foundation
import Testing

@testable import TouchCodeCore

/// Codable round-trip + raw-string contract tests for the GitHub DTOs.
///
/// Enum raw values intentionally match GitHub's GraphQL / REST string form so
/// `gh ... --json ...` output decodes directly. Locking them here prevents a silent
/// drift where the app tier's parsers have to start translating.
struct GitHubModelsCodableTests {
  // MARK: - PullRequestState raw strings

  @Test
  func pullRequestStateRawValues() {
    #expect(PullRequestState.open.rawValue == "OPEN")
    #expect(PullRequestState.merged.rawValue == "MERGED")
    #expect(PullRequestState.closed.rawValue == "CLOSED")
  }

  @Test
  func pullRequestStateDecodesGitHubWireStrings() throws {
    for (wire, expected) in [
      (#""OPEN""#, PullRequestState.open),
      (#""MERGED""#, PullRequestState.merged),
      (#""CLOSED""#, PullRequestState.closed),
    ] {
      let decoded = try JSONDecoder().decode(PullRequestState.self, from: Data(wire.utf8))
      #expect(decoded == expected)
    }
  }

  // MARK: - MergeableState raw strings

  @Test
  func mergeableStateRawValues() {
    #expect(MergeableState.mergeable.rawValue == "MERGEABLE")
    #expect(MergeableState.conflicting.rawValue == "CONFLICTING")
    #expect(MergeableState.unknown.rawValue == "UNKNOWN")
  }

  // MARK: - CheckStatus / CheckConclusion raw strings

  @Test
  func checkStatusRawValues() {
    #expect(CheckStatus.queued.rawValue == "QUEUED")
    #expect(CheckStatus.inProgress.rawValue == "IN_PROGRESS")
    #expect(CheckStatus.completed.rawValue == "COMPLETED")
    #expect(CheckStatus.waiting.rawValue == "WAITING")
    #expect(CheckStatus.pending.rawValue == "PENDING")
  }

  @Test
  func checkConclusionRawValues() {
    #expect(CheckConclusion.success.rawValue == "SUCCESS")
    #expect(CheckConclusion.failure.rawValue == "FAILURE")
    #expect(CheckConclusion.cancelled.rawValue == "CANCELLED")
    #expect(CheckConclusion.skipped.rawValue == "SKIPPED")
    #expect(CheckConclusion.neutral.rawValue == "NEUTRAL")
    #expect(CheckConclusion.timedOut.rawValue == "TIMED_OUT")
    #expect(CheckConclusion.actionRequired.rawValue == "ACTION_REQUIRED")
    #expect(CheckConclusion.stale.rawValue == "STALE")
    #expect(CheckConclusion.startupFailure.rawValue == "STARTUP_FAILURE")
  }

  // MARK: - PullRequestSnapshot round-trip

  @Test
  func pullRequestSnapshotRoundTrip() throws {
    let snapshot = Self.makeSnapshot()
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded == snapshot)
    #expect(decoded.id == snapshot.number)
  }

  @Test
  func pullRequestSnapshotDraftRoundTrip() throws {
    var snapshot = Self.makeSnapshot()
    snapshot.isDraft = true
    snapshot.state = .open
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded.isDraft == true)
    #expect(decoded.state == .open)
  }

  @Test
  func pullRequestSnapshotMergedRoundTripPreservesMergeableUnknown() throws {
    var snapshot = Self.makeSnapshot()
    snapshot.state = .merged
    snapshot.mergeable = .unknown
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded.state == .merged)
    #expect(decoded.mergeable == .unknown)
  }

  // MARK: - CheckResult round-trip

  @Test
  func checkResultCompletedSuccessRoundTrip() throws {
    let check = CheckResult(
      name: "build (macOS)",
      status: .completed,
      conclusion: .success,
      detailsURL: URL(string: "https://github.com/owner/repo/actions/runs/1/job/2")!,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      completedAt: Date(timeIntervalSince1970: 1_700_000_120),
      durationSeconds: 120
    )
    let decoded = try Self.roundTrip(check)
    #expect(decoded == check)
  }

  @Test
  func checkResultPendingNoConclusionRoundTrip() throws {
    let check = CheckResult(name: "ui-snapshots", status: .inProgress)
    let decoded = try Self.roundTrip(check)
    #expect(decoded.status == .inProgress)
    #expect(decoded.conclusion == nil)
    #expect(decoded.detailsURL == nil)
  }

  @Test
  func checkResultIdCompositeFromNameAndStartedAt() {
    let a = CheckResult(name: "build", status: .completed, startedAt: Date(timeIntervalSince1970: 100))
    let b = CheckResult(name: "build", status: .completed, startedAt: Date(timeIntervalSince1970: 200))
    #expect(a.id != b.id, "same name, different start → distinct ids")
  }

  // MARK: - WorkflowRun round-trip

  @Test
  func workflowRunRoundTrip() throws {
    let run = WorkflowRun(
      databaseID: 123_456_789,
      name: "CI",
      status: .completed,
      conclusion: .failure,
      headBranch: "feature/github01",
      headSHA: "aeafe6f012345",
      runNumber: 42,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      url: URL(string: "https://github.com/owner/repo/actions/runs/123456789")!
    )
    let decoded = try Self.roundTrip(run)
    #expect(decoded == run)
    #expect(decoded.id == run.databaseID)
  }

  @Test
  func workflowRunInProgressHasNoConclusion() throws {
    let run = WorkflowRun(
      databaseID: 1,
      name: "CI",
      status: .inProgress,
      conclusion: nil,
      headBranch: "main",
      headSHA: "abc",
      runNumber: 1,
      updatedAt: Date(timeIntervalSince1970: 0),
      url: URL(string: "https://example.com")!
    )
    let decoded = try Self.roundTrip(run)
    #expect(decoded.conclusion == nil)
  }

  // MARK: - Helpers

  private static func makeSnapshot() -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: 1234,
      title: "Fix flaky terminal resize test",
      state: .open,
      isDraft: false,
      headRefName: "feature/github01",
      author: "gump",
      additions: 128,
      deletions: 14,
      commitCount: 3,
      mergeable: .mergeable,
      url: URL(string: "https://github.com/wanggang316/touch-code/pull/1234")!,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoded = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: encoded)
  }
}
