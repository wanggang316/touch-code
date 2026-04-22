import Foundation

/// Permissive Codable for the pre-v2 `settings.json`. Every field is optional because the
/// two historical writers (`SettingsStore` on the editor shape and `NotificationSettingsStore`
/// on the notifications shape) each populated a disjoint subset of top-level keys. A combined
/// file is the third legal case.
///
/// Used by `SettingsMigration.load` to carry user data forward into v2. Not otherwise consumed
/// and never written back to disk.
///
/// C8a retired the custom-editor surface; `customEditors` is no longer decoded here. Legacy
/// files that still carry the key decode fine — the unknown field is ignored.
public nonisolated struct LegacyV1Settings: Decodable, Sendable {
  public let version: Int?
  public let defaultEditorID: EditorID?
  public let notifications: LegacyNotificationsSettings?

  public init(
    version: Int? = nil,
    defaultEditorID: EditorID? = nil,
    notifications: LegacyNotificationsSettings? = nil
  ) {
    self.version = version
    self.defaultEditorID = defaultEditorID
    self.notifications = notifications
  }

  private enum CodingKeys: String, CodingKey {
    case version, defaultEditorID, notifications
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decodeIfPresent(Int.self, forKey: .version)
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
    self.notifications = try container.decodeIfPresent(LegacyNotificationsSettings.self, forKey: .notifications)
  }

  public struct LegacyNotificationsSettings: Decodable, Sendable {
    public let mute: MuteSettings?
    public let authStatus: AuthorizationStatusCache?
    public let neverPrompt: Bool?
    public let notNowUntil: Date?

    public init(
      mute: MuteSettings? = nil,
      authStatus: AuthorizationStatusCache? = nil,
      neverPrompt: Bool? = nil,
      notNowUntil: Date? = nil
    ) {
      self.mute = mute
      self.authStatus = authStatus
      self.neverPrompt = neverPrompt
      self.notNowUntil = notNowUntil
    }

    private enum CodingKeys: String, CodingKey {
      case mute, authStatus, neverPrompt, notNowUntil
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.mute = try container.decodeIfPresent(MuteSettings.self, forKey: .mute)
      self.authStatus = try container.decodeIfPresent(AuthorizationStatusCache.self, forKey: .authStatus)
      self.neverPrompt = try container.decodeIfPresent(Bool.self, forKey: .neverPrompt)
      self.notNowUntil = try container.decodeIfPresent(Date.self, forKey: .notNowUntil)
    }
  }
}
