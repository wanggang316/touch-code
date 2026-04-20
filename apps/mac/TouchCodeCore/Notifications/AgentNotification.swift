import Foundation

/// A single entry in the agent-notification inbox. Persisted; projected over
/// `Catalog` at render time for the user-visible provenance string.
///
/// `panelID` is the provenance pointer. The inbox view joins against `Catalog`
/// at render time to resolve the Panel's Project / Worktree / Tab path; the
/// join is not persisted here because Panels rename and move.
public nonisolated struct AgentNotification: Equatable, Codable, Sendable, Identifiable {
  public let id: UUID
  public let panelID: PanelID
  public let agent: String
  public let kind: Kind
  public let title: String
  public let body: String
  public let createdAt: Date
  public var readAt: Date?
  public var dismissedAt: Date?

  public enum Kind: String, Codable, Sendable, CaseIterable {
    case completed
    case blockedOnInput
    case idle
    case crashed
  }

  public init(
    id: UUID = UUID(),
    panelID: PanelID,
    agent: String,
    kind: Kind,
    title: String,
    body: String,
    createdAt: Date = Date(),
    readAt: Date? = nil,
    dismissedAt: Date? = nil
  ) {
    self.id = id
    self.panelID = panelID
    self.agent = agent
    self.kind = kind
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.readAt = readAt
    self.dismissedAt = dismissedAt
  }

  /// True iff the notification has not been read and has not been dismissed.
  /// Drives the Dock badge count (design DEC-13) — badge mirrors the inbox
  /// "Unread" filter regardless of OS-banner mute status.
  public var isUnread: Bool {
    readAt == nil && dismissedAt == nil
  }
}
