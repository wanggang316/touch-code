import Foundation
import os.log

/// Shared file-aside helper used by every C6 persistence store whose decoder
/// aborts on unknown version (architecture invariant) or unrecoverable decode
/// error. Keeps the backup filename pattern, fallback semantics, and formatter
/// reuse in a single place so future schema-version bumps only have to update
/// one file.
///
/// Protocol:
/// 1. Rename the original to `<filename>.broken-<ISO8601>` alongside.
/// 2. If rename fails (cross-volume, permissions), copy+delete as a fallback.
/// 3. If that fails too, log at `.error` and leave the original in place so the
///    operator can recover manually. The next writer will clobber it, but the
///    log entry is the forensic trail.
nonisolated enum BrokenFileBackup {
  /// Move the file at `fileURL` aside to a sibling `<name>.broken-<ISO8601>`.
  /// `logger` receives a `.warning` on fallback and `.error` on full failure.
  static func moveAside(at fileURL: URL, logger: Logger) {
    let timestamp = formatter.string(from: Date())
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).broken-\(timestamp)")

    do {
      try FileManager.default.moveItem(at: fileURL, to: backupURL)
      return
    } catch {
      logger.warning("Move-to-backup failed (\(String(describing: error))); falling back to copy+delete.")
    }

    do {
      try FileManager.default.copyItem(at: fileURL, to: backupURL)
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      logger.error(
        "Backup copy+delete also failed (\(String(describing: error))); corrupt file remains at \(fileURL.path).")
    }
  }

  /// Shared ISO-8601 formatter — thread-safe for reads after configuration.
  /// Per Apple docs, `ISO8601DateFormatter.string(from:)` can be called
  /// concurrently once `formatOptions` has been set. `nonisolated(unsafe)`
  /// opts out of Swift 6's concurrency check with that rationale; the value
  /// is configured exactly once at lazy-init and never mutated afterwards.
  private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}
