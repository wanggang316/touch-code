import Foundation
import os.log

/// Entry point for loading `settings.json`: tries v2 first, falls back to v1 with a
/// permissive legacy decode, backs aside anything that can neither be parsed nor recognised.
/// `SettingsStore` delegates its initial load through `SettingsMigration.load` in Step 4.
///
/// The migration algorithm is documented in docs/design-docs/settings-base.md §Data Storage.
///
/// ## Atomicity invariant (PR #22 review B1/B2)
///
/// Data safety on the migration path is critical: a crash or partial failure must never
/// destroy the user's historical settings without producing a recoverable backup. The legacy
/// migration branch uses the sequence below, executed inside `load` so the caller can treat
/// `.migratedFromV1` as "both files durably on disk, caller need not write anything":
///
/// 1. Encode the migrated v2 tree and write it through `AtomicFileStore.write` to a
///    sibling temp URL (`<settings>.new-<uuid>`) — fsync inside AtomicFileStore means
///    the temp is durable before the next step runs.
/// 2. `rename(2)` the original v1 file to `settings.json.v1-<yyyyMMdd-HHmmss>`. After this
///    returns the backup has committed; the original path is empty.
/// 3. `rename(2)` the temp into the original path. The v2 file is durable at the
///    canonical URL, the backup at `.v1-<ts>`.
///
/// Failure handling per step:
/// - Step 1 fails → no changes on disk; `.migrationBackupFailed` returned.
/// - Step 2 fails → delete the temp, original still canonical; `.migrationBackupFailed`.
/// - Step 3 fails → attempt to restore the original by renaming the backup back; delete
///   the temp; `.migrationBackupFailed`.
///
/// The brief interval between step 2 and step 3 is the only window where the canonical
/// path is missing. A crash there leaves the durable backup — the next launch sees a
/// fresh file and the user can recover from `.v1-<ts>` manually.
public nonisolated enum SettingsMigration {
  public enum LoadOutcome: Equatable {
    /// File did not exist on disk; caller starts from defaults.
    case fresh
    /// File decoded as current-version v2; no migration required.
    case v2(Settings)
    /// File decoded under the permissive v1 shape; caller already sees the v2 tree on
    /// disk at the canonical URL, and the original v1 content is preserved at `backupURL`.
    /// Caller must NOT call `AtomicFileStore.write` again — both writes already landed.
    case migratedFromV1(Settings, backupURL: URL)
    /// File carried an unrecognised `version` number. Original renamed to
    /// `settings.json.broken-<yyyyMMdd-HHmmss>`; caller starts from defaults.
    case unsupported(Int, backupURL: URL)
    /// File was present but unparseable (not v2 shape, not legacy shape). Original renamed
    /// to `settings.json.broken-<yyyyMMdd-HHmmss>`; caller starts from defaults.
    case corrupt(backupURL: URL)
    /// Migration attempted but the atomic sequence could not complete. The user's original
    /// v1 file is still at the canonical URL (or restored there) — no data was destroyed.
    /// Caller should start from defaults, log prominently, and MUST NOT persist anything
    /// on top of the canonical URL; doing so would overwrite the still-intact v1 data.
    case migrationBackupFailed(description: String)
  }

  /// Logger category used by the migration path. Distinct from `"settings"` so traces can be
  /// filtered — `log stream --predicate 'subsystem == "com.touch-code.persistence" && category == "migration"'`.
  public static let logger = Logger(subsystem: "com.touch-code.persistence", category: "migration")

  /// Load the settings file at `url` and return how it was handled. Side effects: if a
  /// backup is produced OR the migrated v2 is installed, disk state is updated before the
  /// function returns. `clock` supplies the timestamp used in backup filenames — injected
  /// for test determinism.
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
      switch moveAside(url: url, prefix: "settings.json.broken-", at: clock(), fileManager: fileManager) {
      case .success(let backup):
        logger.error(
          "Unsupported settings.json version \(version, privacy: .public); backed up to \(backup.lastPathComponent, privacy: .public)"
        )
        return .unsupported(version, backupURL: backup)
      case .failure(let error):
        logger.error("Unsupported version and backup move failed: \(String(describing: error), privacy: .public)")
        return .migrationBackupFailed(description: "moveAside failed for unsupported version: \(error)")
      }
    } catch {
      // Fall through to legacy decode — a version:1 file throws `unsupportedVersion(1)` here.
    }

    // Legacy v1 shape — permissive. Historical writers both wrote `version: 1`; the helper
    // accepts even a missing `version` field so a crash mid-write during the pre-v2 era
    // still decodes.
    do {
      let legacy = try JSONDecoder.touchCodeDefault.decode(LegacyV1Settings.self, from: data)
      let migrated = migrate(legacy)
      return performV1Migration(
        url: url,
        migrated: migrated,
        now: clock(),
        fileManager: fileManager
      )
    } catch {
      switch moveAside(url: url, prefix: "settings.json.broken-", at: clock(), fileManager: fileManager) {
      case .success(let backup):
        logger.error(
          "Could not parse settings.json at all; backed up to \(backup.lastPathComponent, privacy: .public). Error: \(String(describing: error), privacy: .public)"
        )
        return .corrupt(backupURL: backup)
      case .failure(let moveError):
        logger.error(
          "Unparseable settings.json and backup move failed: \(String(describing: moveError), privacy: .public)")
        return .migrationBackupFailed(description: "moveAside failed for corrupt JSON: \(moveError)")
      }
    }
  }

  /// Pure mapping from the legacy permissive struct to a v2 Settings tree. Fields absent in
  /// the legacy object fall through to v2 defaults. Exposed independently so tests don't have
  /// to round-trip through the filesystem.
  public static func migrate(_ legacy: LegacyV1Settings) -> Settings {
    var general = GeneralSettings.default
    general.defaultEditorID = legacy.defaultEditorID
    // C8a: legacy `customEditors` array is ignored on migration — see GeneralSettings doc.

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

  /// Runs the v1 → v2 atomic migration sequence documented at the top of this file. Returns
  /// `.migratedFromV1` when every step committed durably, `.migrationBackupFailed` otherwise.
  /// On failure the canonical URL still holds the user's original v1 content (restored if
  /// necessary). Callers on the failure path must not overwrite the canonical URL.
  private static func performV1Migration(
    url: URL,
    migrated: Settings,
    now: Date,
    fileManager: FileManager
  ) -> LoadOutcome {
    let timestamp = filesystemSafeTimestamp(now)
    let backupURL = url.deletingLastPathComponent()
      .appendingPathComponent("settings.json.v1-\(timestamp)", isDirectory: false)
    let tempURL = url.deletingLastPathComponent()
      .appendingPathComponent(".settings.json.new-\(UUID().uuidString)", isDirectory: false)

    // Step 1 — encode + fsync migrated v2 into a sibling temp file. AtomicFileStore uses its
    // own write-and-fsync pattern so the contents are durably on disk when this returns.
    do {
      try AtomicFileStore.write(migrated, to: tempURL)
    } catch {
      logger.error("Migration step 1 (write-to-temp) failed: \(String(describing: error), privacy: .public)")
      return .migrationBackupFailed(description: "write-to-temp failed: \(error)")
    }

    // Step 2 — rename original → backup. After this succeeds the v1 content is durably
    // preserved under `.v1-<ts>`; the canonical path is empty for a brief moment.
    do {
      try fileManager.moveItem(at: url, to: backupURL)
    } catch {
      try? fileManager.removeItem(at: tempURL)
      logger.error(
        "Migration step 2 (rename-original-to-backup) failed: \(String(describing: error), privacy: .public)")
      return .migrationBackupFailed(description: "rename to backup failed: \(error)")
    }

    // Step 3 — rename temp → canonical. On failure, try to undo step 2 so the user sees the
    // original at the canonical URL again; either way, surface the failure to the caller.
    do {
      try fileManager.moveItem(at: tempURL, to: url)
    } catch {
      logger.error("Migration step 3 (rename-temp-to-canonical) failed: \(String(describing: error), privacy: .public)")
      // Best-effort recovery: put the backup back at the canonical URL. If that also fails,
      // the user's data is still recoverable — it's just at the backup filename.
      try? fileManager.moveItem(at: backupURL, to: url)
      try? fileManager.removeItem(at: tempURL)
      return .migrationBackupFailed(description: "rename temp to canonical failed: \(error)")
    }

    logger.info("Migrated v1 settings.json to v2; backup at \(backupURL.lastPathComponent, privacy: .public)")
    return .migratedFromV1(migrated, backupURL: backupURL)
  }

  /// Non-atomic move of a file to a backup filename. Used for the `unsupported` and
  /// `corrupt` branches where the file is unparseable and the caller wants to clear the
  /// canonical path before starting fresh. Returns `.failure` if the rename fails — the
  /// caller is expected to fall back to `.migrationBackupFailed` rather than clobber the
  /// file on disk.
  private static func moveAside(
    url: URL,
    prefix: String,
    at now: Date,
    fileManager: FileManager
  ) -> Result<URL, Error> {
    let backup = url.deletingLastPathComponent()
      .appendingPathComponent("\(prefix)\(filesystemSafeTimestamp(now))", isDirectory: false)
    do {
      try fileManager.moveItem(at: url, to: backup)
      return .success(backup)
    } catch {
      return .failure(error)
    }
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
