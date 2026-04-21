import Foundation

/// `notifications` sub-tree of `settings.json` (v2). Superset of the v1 `NotificationsSettings`
/// shape the now-deleted `NotificationSettingsStore` used: existing fields (`mute`, `authStatus`,
/// `neverPrompt`, `notNowUntil`) carry over unchanged so the v1→v2 migration is lossless, and
/// four UI-owned toggles (`inAppEnabled`, `systemEnabled`, `soundEnabled`, `dockBadgeEnabled`)
/// are added for spec M5. `dockBadgeEnabled` tracks the v1 `mute.badgeEnabled` on migration.
public nonisolated struct NotificationsSettings: Equatable, Codable, Sendable {
  public var mute: MuteSettings
  public var authStatus: AuthorizationStatusCache
  public var neverPrompt: Bool
  /// Timestamp after which the coordinator may present the pre-prompt again after a `.notNow`
  /// decision. `nil` means no cool-down active.
  public var notNowUntil: Date?
  /// Global kill switch for in-app notifications (spec M5.1). `true` by default — preserves
  /// pre-v2 behaviour where in-app banners were always emitted when not muted.
  public var inAppEnabled: Bool
  /// Toggles macOS user-notification banners (spec M5.2).
  public var systemEnabled: Bool
  /// Toggles the notification sound (spec M5.3).
  public var soundEnabled: Bool
  /// Toggles the Dock badge (spec M5.4). Default reflects v1 `mute.badgeEnabled`.
  public var dockBadgeEnabled: Bool

  public init(
    mute: MuteSettings = .defaults,
    authStatus: AuthorizationStatusCache = .notDetermined,
    neverPrompt: Bool = false,
    notNowUntil: Date? = nil,
    inAppEnabled: Bool = true,
    systemEnabled: Bool = true,
    soundEnabled: Bool = true,
    dockBadgeEnabled: Bool = true
  ) {
    self.mute = mute
    self.authStatus = authStatus
    self.neverPrompt = neverPrompt
    self.notNowUntil = notNowUntil
    self.inAppEnabled = inAppEnabled
    self.systemEnabled = systemEnabled
    self.soundEnabled = soundEnabled
    self.dockBadgeEnabled = dockBadgeEnabled
  }

  public static let `default` = NotificationsSettings()

  private enum CodingKeys: String, CodingKey {
    case mute, authStatus, neverPrompt, notNowUntil
    case inAppEnabled, systemEnabled, soundEnabled, dockBadgeEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.mute = try container.decodeIfPresent(MuteSettings.self, forKey: .mute) ?? .defaults
    self.authStatus = try container.decodeIfPresent(AuthorizationStatusCache.self, forKey: .authStatus) ?? .notDetermined
    self.neverPrompt = try container.decodeIfPresent(Bool.self, forKey: .neverPrompt) ?? false
    self.notNowUntil = try container.decodeIfPresent(Date.self, forKey: .notNowUntil)
    self.inAppEnabled = try container.decodeIfPresent(Bool.self, forKey: .inAppEnabled) ?? true
    self.systemEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemEnabled) ?? true
    self.soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
    self.dockBadgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockBadgeEnabled) ?? true
  }
}

/// Persisted mirror of `UserNotifications.UNAuthorizationStatus`. Kept as a separate type because
/// the `UserNotifications` framework lives in the app target — `TouchCodeCore` must not import it.
public nonisolated enum AuthorizationStatusCache: String, Equatable, Codable, Sendable {
  case notDetermined
  case authorized
  case denied
  case provisional

  public var isAuthorized: Bool {
    switch self {
    case .authorized, .provisional: return true
    case .notDetermined, .denied: return false
    }
  }
}
