import Foundation

/// A single entry in the agent-notification inbox. Persisted; projected over
/// `Catalog` at render time for the user-visible provenance string.
///
/// `paneID` is the provenance pointer. The inbox view joins against `Catalog`
/// at render time to resolve the Pane's Project / Worktree / Tab path; the
/// join is not persisted here because Panes rename and move.
public nonisolated struct AgentNotification: Equatable, Codable, Sendable, Identifiable {
  public let id: UUID
  public let paneID: PaneID
  public let agent: String
  public let kind: Kind
  public let title: String
  public let body: String
  public let createdAt: Date
  public var readAt: Date?
  public var dismissedAt: Date?
  /// Optional stable identity for cross-source deduplication. When two
  /// signal sources describe the same event (e.g. an agent's Stop hook
  /// and the terminal's OSC 9 sequence firing within milliseconds of
  /// each other for the same completion), they may set the same
  /// `dedupKey` so the coordinator drops the duplicate within its
  /// 2-second window instead of stacking two inbox rows. `nil` means
  /// "no explicit identity" — the coordinator falls back to a content
  /// hash of `(paneID, title, body)`. Decoded with `decodeIfPresent`
  /// so v1 `notifications.json` files round-trip unchanged.
  public var dedupKey: String?

  public enum Kind: String, Codable, Sendable, CaseIterable {
    case completed
    case blockedOnInput
    case idle
    case crashed
  }

  public init(
    id: UUID = UUID(),
    paneID: PaneID,
    agent: String,
    kind: Kind,
    title: String,
    body: String,
    createdAt: Date = Date(),
    readAt: Date? = nil,
    dismissedAt: Date? = nil,
    dedupKey: String? = nil
  ) {
    self.id = id
    self.paneID = paneID
    self.agent = agent
    self.kind = kind
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.readAt = readAt
    self.dismissedAt = dismissedAt
    self.dedupKey = dedupKey
  }

  private enum CodingKeys: String, CodingKey {
    case id, paneID, agent, kind, title, body, createdAt, readAt, dismissedAt, dedupKey
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.paneID = try container.decode(PaneID.self, forKey: .paneID)
    self.agent = try container.decode(String.self, forKey: .agent)
    self.kind = try container.decode(Kind.self, forKey: .kind)
    self.title = try container.decode(String.self, forKey: .title)
    self.body = try container.decode(String.self, forKey: .body)
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
    self.dismissedAt = try container.decodeIfPresent(Date.self, forKey: .dismissedAt)
    self.dedupKey = try container.decodeIfPresent(String.self, forKey: .dedupKey)
  }

  /// True iff the notification has not been read and has not been dismissed.
  /// Drives the Dock badge count (design DEC-13) — badge mirrors the inbox
  /// "Unread" filter regardless of OS-banner mute status.
  public var isUnread: Bool {
    readAt == nil && dismissedAt == nil
  }
}
