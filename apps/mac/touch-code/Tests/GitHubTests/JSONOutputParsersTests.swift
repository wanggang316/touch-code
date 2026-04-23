import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

struct JSONOutputParsersTests {
  // MARK: - gh auth status

  @Test
  func parseAuthStatusAvailableReturnsHostAndUser() throws {
    let data = try Self.loadFixture("gh-auth-status-available")
    let result = try JSONOutputParsers.parseAuthStatus(data)
    #expect(result?.host == "github.com")
    #expect(result?.user == "gump")
  }

  @Test
  func parseAuthStatusUnauthReturnsNil() throws {
    let data = try Self.loadFixture("gh-auth-status-unauth")
    let result = try JSONOutputParsers.parseAuthStatus(data)
    #expect(result == nil)
  }

  // MARK: - gh pr view

  @Test
  func parsePullRequestOpenSurfacesAllFields() throws {
    let data = try Self.loadFixture("gh-pr-view-open")
    let snapshot = try JSONOutputParsers.parsePullRequest(data)
    let unwrapped = try #require(snapshot)
    #expect(unwrapped.number == 1234)
    #expect(unwrapped.title == "Fix flaky terminal resize test")
    #expect(unwrapped.state == .open)
    #expect(unwrapped.isDraft == false)
    #expect(unwrapped.headRefName == "feature/github01")
    #expect(unwrapped.author == "gump")
    #expect(unwrapped.additions == 128)
    #expect(unwrapped.deletions == 14)
    #expect(unwrapped.commitCount == 3)
    #expect(unwrapped.mergeable == .mergeable)
    #expect(unwrapped.url.absoluteString == "https://github.com/wanggang316/touch-code/pull/1234")
  }

  @Test
  func parsePullRequestDraftFlagsIsDraft() throws {
    let data = try Self.loadFixture("gh-pr-view-draft")
    let snapshot = try JSONOutputParsers.parsePullRequest(data)
    let unwrapped = try #require(snapshot)
    #expect(unwrapped.isDraft == true)
    #expect(unwrapped.state == .open)
    #expect(unwrapped.mergeable == .unknown)
    #expect(unwrapped.commitCount == 1)
  }

  @Test
  func parsePullRequestMerged() throws {
    let data = try Self.loadFixture("gh-pr-view-merged")
    let snapshot = try JSONOutputParsers.parsePullRequest(data)
    let unwrapped = try #require(snapshot)
    #expect(unwrapped.state == .merged)
    #expect(unwrapped.commitCount == 5)
  }

  @Test
  func parsePullRequestClosedCarriesConflictingMergeable() throws {
    let data = try Self.loadFixture("gh-pr-view-closed")
    let snapshot = try JSONOutputParsers.parsePullRequest(data)
    let unwrapped = try #require(snapshot)
    #expect(unwrapped.state == .closed)
    #expect(unwrapped.mergeable == .conflicting)
  }

  @Test
  func parsePullRequestEmptyObjectReturnsNil() throws {
    let data = Data("{}".utf8)
    let snapshot = try JSONOutputParsers.parsePullRequest(data)
    #expect(snapshot == nil)
  }

  // MARK: - gh pr checks

  @Test
  func parseChecksMixedSplitsStateCorrectly() throws {
    let data = try Self.loadFixture("gh-pr-checks-mixed")
    let checks = try JSONOutputParsers.parseChecks(data)
    #expect(checks.count == 5)

    let byName = Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0) })
    let build = try #require(byName["build (macOS)"])
    #expect(build.status == .completed)
    #expect(build.conclusion == .success)
    #expect(build.durationSeconds == 102)  // 05:01:42 - 05:00:00

    let ui = try #require(byName["ui-snapshots (macOS)"])
    #expect(ui.status == .completed)
    #expect(ui.conclusion == .failure)

    let lint = try #require(byName["lint"])
    #expect(lint.status == .queued)
    #expect(lint.conclusion == nil)
    #expect(lint.completedAt == nil)
    #expect(lint.durationSeconds == nil)

    let lockfile = try #require(byName["lockfile"])
    #expect(lockfile.status == .completed)
    #expect(lockfile.conclusion == .skipped)
    #expect(lockfile.startedAt == nil)
  }

  @Test
  func parseChecksEmpty() throws {
    let data = try Self.loadFixture("gh-pr-checks-none")
    let checks = try JSONOutputParsers.parseChecks(data)
    #expect(checks.isEmpty)
  }

  @Test
  func splitCheckStateUnknownFallsBackToPending() {
    let (status, conclusion) = JSONOutputParsers.splitCheckState("something-new")
    #expect(status == .inProgress)
    #expect(conclusion == nil)
  }

  @Test
  func splitCheckStateHandlesCaseVariants() {
    #expect(JSONOutputParsers.splitCheckState("success").0 == .completed)
    #expect(JSONOutputParsers.splitCheckState("failed").1 == .failure)
    #expect(JSONOutputParsers.splitCheckState("canceled").1 == .cancelled)
  }

  // MARK: - gh run list

  @Test
  func parseLatestWorkflowRunSuccess() throws {
    let data = try Self.loadFixture("gh-run-list-success")
    let run = try JSONOutputParsers.parseLatestWorkflowRun(data)
    let unwrapped = try #require(run)
    #expect(unwrapped.databaseID == 123_456_789)
    #expect(unwrapped.status == .completed)
    #expect(unwrapped.conclusion == .success)
    #expect(unwrapped.headBranch == "feature/github01")
    #expect(unwrapped.runNumber == 42)
  }

  @Test
  func parseLatestWorkflowRunFailure() throws {
    let data = try Self.loadFixture("gh-run-list-failure")
    let run = try JSONOutputParsers.parseLatestWorkflowRun(data)
    let unwrapped = try #require(run)
    #expect(unwrapped.conclusion == .failure)
    #expect(unwrapped.databaseID == 987_654_321)
  }

  @Test
  func parseLatestWorkflowRunEmptyReturnsNil() throws {
    let data = try Self.loadFixture("gh-run-list-empty")
    let run = try JSONOutputParsers.parseLatestWorkflowRun(data)
    #expect(run == nil)
  }

  // MARK: - Malformed input

  @Test
  func parsePullRequestOnNonJSONThrowsGitHubError() {
    let data = Data("not json".utf8)
    do {
      _ = try JSONOutputParsers.parsePullRequest(data)
      Issue.record("expected .other throw")
    } catch let error as GitHubError {
      if case .other = error { return }
      Issue.record("expected .other, got \(error)")
    } catch {
      Issue.record("expected GitHubError, got \(type(of: error))")
    }
  }

  // MARK: - Fixture loading

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
