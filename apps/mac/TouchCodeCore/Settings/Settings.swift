import Foundation
import os.log

/// Root Codable of `~/.config/touch-code/settings.json` (v2). Replaces the v1 Settings struct
/// (editor-only) and the v1 TouchCodeSettings struct (notifications-only) that used to race
/// the same file with disjoint schemas. Single writer — `SettingsStore` — owns the whole tree;
/// readers that see `version != 2` back the file up and start from defaults.
///
/// Per-Repository data (default-editor override, worktree base directory) lives on `Project` in
/// `catalog.json`; `Settings.repositories` is a reserved slot for future per-Repo preferences
/// that do not belong on the catalog. See design doc §Repository scope (D1).
public nonisolated struct Settings: Equatable, Sendable {
  public static let currentVersion = 2

  public var version: Int
  public var general: GeneralSettings
  public var notifications: NotificationsSettings
  public var developer: DeveloperSettings
  public var repositories: [ProjectID: RepositorySettings]

  public init(
    version: Int = Settings.currentVersion,
    general: GeneralSettings = .default,
    notifications: NotificationsSettings = .default,
    developer: DeveloperSettings = .default,
    repositories: [ProjectID: RepositorySettings] = [:]
  ) {
    self.version = version
    self.general = general
    self.notifications = notifications
    self.developer = developer
    self.repositories = repositories
  }

  public static let `default` = Settings()

  /// Canonical on-disk location: `~/.config/touch-code/settings.json`.
  public static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("settings.json", isDirectory: false)
  }

  /// Drop any `repositories[id]` entry whose value is effectively empty. Called by
  /// `SettingsStore` before each save so `settings.json` does not retain `{}` placeholders.
  public mutating func garbageCollect() {
    repositories = repositories.filter { _, value in !value.isEffectivelyEmpty }
  }

  /// Resets any stored editor ID that is not in the caller-provided built-in registry to
  /// `nil`. Run once at load so the in-memory `Settings` tree only references editors that
  /// the app currently knows about — stale IDs from the retired C8 `customEditors` feature
  /// would otherwise linger in `settings.json` forever (the resolver is lenient and would
  /// silently fall back, but the stored value stays dead).
  ///
  /// `knownIDs` is passed in rather than imported so this helper stays in `TouchCodeCore`
  /// without taking a dependency on the app-tier `EditorRegistry`. Idempotent — a second
  /// call on an already-cleaned `Settings` is a no-op and returns `false`.
  ///
  /// Returns `true` if any field was mutated so the caller can decide whether to persist.
  @discardableResult
  public mutating func garbageCollectEditors(knownIDs: Set<EditorID>) -> Bool {
    guard let id = general.defaultEditorID, !knownIDs.contains(id) else { return false }
    general.defaultEditorID = nil
    return true
  }
}

extension Settings: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case version, general, notifications, developer, repositories
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Settings.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = version
    self.general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .default
    self.notifications = try container.decodeIfPresent(NotificationsSettings.self, forKey: .notifications) ?? .default
    self.developer = try container.decodeIfPresent(DeveloperSettings.self, forKey: .developer) ?? .default

    // `repositories` is encoded as a JSON object keyed by the ProjectID UUID string so the file
    // is human-diffable and hand-editable. ProjectID itself is a Codable struct (encoded as
    // `{ "raw": "<uuid>" }` by default) which would force an array-of-pairs layout — we decode
    // the String-keyed form and convert. Unparseable keys are dropped with a log line so a
    // hand-edit typo doesn't abort the whole file load.
    let raw = try container.decodeIfPresent([String: RepositorySettings].self, forKey: .repositories) ?? [:]
    var mapped: [ProjectID: RepositorySettings] = [:]
    mapped.reserveCapacity(raw.count)
    let logger = Logger(subsystem: "com.touch-code.persistence", category: "settings")
    for (stringKey, value) in raw {
      if let uuid = UUID(uuidString: stringKey) {
        mapped[ProjectID(raw: uuid)] = value
      } else {
        logger.warning("Dropping unparseable repositories key: \(stringKey, privacy: .public)")
      }
    }
    self.repositories = mapped
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(general, forKey: .general)
    try container.encode(notifications, forKey: .notifications)
    try container.encode(developer, forKey: .developer)
    var stringKeyed: [String: RepositorySettings] = [:]
    stringKeyed.reserveCapacity(repositories.count)
    for (projectID, value) in repositories {
      stringKeyed[projectID.raw.uuidString] = value
    }
    try container.encode(stringKeyed, forKey: .repositories)
  }
}
