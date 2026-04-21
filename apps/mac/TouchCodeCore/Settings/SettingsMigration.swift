import Foundation
import os.log

/// Entry point for loading `settings.json`: tries v2 first, falls back to v1 with a
/// permissive legacy decode, backs aside anything that can neither be parsed nor recognised.
/// `SettingsStore` delegates its initial load through `SettingsMigration.load` in Step 4.
///
/// The migration algorithm is documented in docs/design-docs/settings-base.md §Data Storage.
public nonisolated enum SettingsMigration {
  public enum LoadOutcome: Equatable {
    /// File did not exist on disk; caller starts from defaults.
    case fresh
    /// File decoded as current-version v2; no migration required.
    case v2(Settings)
    /// File decoded under the permissive v1 shape; caller persists the returned v2 tree and
    /// the original file has been renamed to `settings.json.v1-<yyyyMMdd-HHmmss>`.
    case migratedFromV1(Settings, backupURL: URL)
    /// File carried an unrecognised `version` number. Original renamed to
    /// `settings.json.broken-<yyyyMMdd-HHmmss>`; caller starts from defaults.
    case unsupported(Int, backupURL: URL)
    /// File was present but unparseable (not v2 shape, not legacy shape). Original renamed
    /// to `settings.json.broken-<yyyyMMdd-HHmmss>`; caller starts from defaults.
    case corrupt(backupURL: URL)
  }

  /// Logger category used by the migration path. Distinct from `"settings"` so traces can be
  /// filtered — `log stream --predicate 'subsystem == "com.touch-code.persistence" && category == "migration"'`.
  public static let logger = Logger(subsystem: "com.touch-code.persistence", category: "migration")

  /// Load the settings file at `url` and return how it was handled. Side effects: if a backup
  /// is produced, the original file is renamed on disk before the function returns. `clock`
  /// supplies the timestamp used in backup filenames — injected for test determinism.
  public static func load(
    from url: URL,
    fileManager: FileManager = .default,
    clock: @Sendable () -> Date = { Date() }
  ) throws -> LoadOutcome {
    guard fileManager.fileExists(atPath: url.path) else { return .fresh }

    let data = try Data(contentsOf: url)

    // v2 first — the common case once migration has run.
    do {
      let settings = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
      return .v2(settings)
    } catch Settings.DecodingIssue.unsupportedVersion(let version) where version != 1 {
      let backup = moveAside(url: url, prefix: "settings.json.broken-", at: clock(), fileManager: fileManager)
      logger.error("Unsupported settings.json version \(version, privacy: .public); backed up to \(backup.lastPathComponent, privacy: .public)")
      return .unsupported(version, backupURL: backup)
    } catch {
      // Fall through to legacy decode — a version:1 file throws `unsupportedVersion(1)` here.
    }

    // Legacy v1 shape — permissive. If the version field is missing entirely we still accept
    // the file because the two historical writers both wrote `version: 1` and disjoint
    // writers could technically have produced a partial file during a crash.
    do {
      let legacy = try JSONDecoder.touchCodeDefault.decode(LegacyV1Settings.self, from: data)
      let migrated = migrate(legacy)
      let backup = moveAside(url: url, prefix: "settings.json.v1-", at: clock(), fileManager: fileManager)
      logger.info("Migrated v1 settings.json to v2; backup at \(backup.lastPathComponent, privacy: .public)")
      return .migratedFromV1(migrated, backupURL: backup)
    } catch {
      let backup = moveAside(url: url, prefix: "settings.json.broken-", at: clock(), fileManager: fileManager)
      logger.error("Could not parse settings.json at all; backed up to \(backup.lastPathComponent, privacy: .public). Error: \(String(describing: error), privacy: .public)")
      return .corrupt(backupURL: backup)
    }
  }

  /// Pure mapping from the legacy permissive struct to a v2 Settings tree. Fields absent in
  /// the legacy object fall through to v2 defaults. Exposed independently so tests don't have
  /// to round-trip through the filesystem.
  public static func migrate(_ legacy: LegacyV1Settings) -> Settings {
    var general = GeneralSettings.default
    general.defaultEditorID = legacy.defaultEditorID
    general.customEditors = legacy.customEditors ?? []

    var notifications = NotificationsSettings.default
    if let legacyNotif = legacy.notifications {
      notifications.mute = legacyNotif.mute ?? .defaults
      notifications.authStatus = legacyNotif.authStatus ?? .notDetermined
      notifications.neverPrompt = legacyNotif.neverPrompt ?? false
      notifications.notNowUntil = legacyNotif.notNowUntil
      // v1 had `mute.badgeEnabled` as the Dock-badge proxy. Pull that through to the v2
      // dedicated toggle so existing "I turned off the dock badge" preferences are preserved.
      notifications.dockBadgeEnabled = legacyNotif.mute?.badgeEnabled ?? true
    }

    return Settings(
      version: Settings.currentVersion,
      general: general,
      notifications: notifications,
      developer: .default,
      repositories: [:]
    )
  }

  // MARK: - Private helpers

  @discardableResult
  private static func moveAside(
    url: URL,
    prefix: String,
    at now: Date,
    fileManager: FileManager
  ) -> URL {
    let backup = url.deletingLastPathComponent()
      .appendingPathComponent("\(prefix)\(filesystemSafeTimestamp(now))", isDirectory: false)
    try? fileManager.moveItem(at: url, to: backup)
    return backup
  }

  /// `yyyyMMdd-HHmmss` UTC. Filesystem-safe across case-insensitive and ':'-averse tooling.
  private static func filesystemSafeTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
