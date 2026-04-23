import Foundation

/// A compact view of one GitHub pull request tied to a Worktree. Decoded from
/// `gh pr view --json ...` output by the app-tier `JSONOutputParsers`; the DTO itself
/// uses GitHub's string enum values verbatim so the wire JSON decodes directly.
///
/// Lives in `TouchCodeCore` rather than the app-tier `touch-code/GitHub/` so a future
/// `tc` IPC surface (`github.*` methods, deferred to v2) can ship the same value type
/// without a refactor. See `docs/exec-plans/0012-github-integration.md` DEC-7.
public struct PullRequestSnapshot: Equatable, Codable, Sendable, Identifiable {
  public var id: Int { number }
  public var number: Int
  public var title: String
  public var state: PullRequestState
  public var isDraft: Bool
  public var headRefName: String
  public var author: String
  public var additions: Int
  public var deletions: Int
  public var commitCount: Int
  public var mergeable: MergeableState
  public var url: URL
  public var updatedAt: Date

  public init(
    number: Int,
    title: String,
    state: PullRequestState,
    isDraft: Bool,
    headRefName: String,
    author: String,
    additions: Int,
    deletions: Int,
    commitCount: Int,
    mergeable: MergeableState,
    url: URL,
    updatedAt: Date
  ) {
    self.number = number
    self.title = title
    self.state = state
    self.isDraft = isDraft
    self.headRefName = headRefName
    self.author = author
    self.additions = additions
    self.deletions = deletions
    self.commitCount = commitCount
    self.mergeable = mergeable
    self.url = url
    self.updatedAt = updatedAt
  }
}

/// Lifecycle state of a pull request. Raw values match the GraphQL enum strings that
/// `gh pr view --json state` emits, so JSON decode is a one-hop pass-through.
public enum PullRequestState: String, Codable, Sendable, CaseIterable {
  case open = "OPEN"
  case merged = "MERGED"
  case closed = "CLOSED"
}

/// Merge feasibility as reported by GitHub. `.unknown` is the transient state while
/// GitHub computes mergeability on the server — not an error.
public enum MergeableState: String, Codable, Sendable, CaseIterable {
  case mergeable = "MERGEABLE"
  case conflicting = "CONFLICTING"
  case unknown = "UNKNOWN"
}
