import Foundation

/// The on-disk shape of `~/.config/touch-code/notifications.json`.
///
/// Plain projection. The 500-row cap and 7-day soft-delete sweep from the
/// design doc live in `InboxStore` (app-side M3), not here — we keep this
/// struct value-only so it can round-trip through `AtomicFileStore` without
/// carrying lifecycle concerns.
///
/// Schema evolution follows the architecture invariant: readers that
/// encounter an unknown `version` abort rather than silently upgrade.
public nonisolated struct NotificationInbox: Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var notifications: [AgentNotification]

  public init(
    version: Int = NotificationInbox.currentVersion,
    notifications: [AgentNotification] = []
  ) {
    self.version = version
    self.notifications = notifications
  }

  public static let empty = NotificationInbox()
}

extension NotificationInbox: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey { case version, notifications }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == NotificationInbox.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = version
    self.notifications = try container.decodeIfPresent([AgentNotification].self, forKey: .notifications) ?? []
  }
}
