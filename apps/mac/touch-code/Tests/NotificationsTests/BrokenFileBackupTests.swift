import Foundation
import Testing
import os.log

@testable import touch_code

struct BrokenFileBackupTests {
  @Test
  func moveAsideRenamesFileWithIsoTimestampSuffix() throws {
    let dir = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("payload.json")
    try Data("hello".utf8).write(to: url)

    let logger = Logger(subsystem: "test", category: "backup")
    BrokenFileBackup.moveAside(at: url, logger: logger)

    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let backups = contents.filter { $0.hasPrefix("payload.json.broken-") }
    #expect(contents.contains("payload.json") == false)
    #expect(backups.count == 1)

    // Backup content matches original input.
    let backupURL = dir.appendingPathComponent(backups[0])
    let restored = try Data(contentsOf: backupURL)
    #expect(restored == Data("hello".utf8))
  }

  @Test
  func moveAsideOnMissingFileIsQuiet() throws {
    let dir = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("does-not-exist.json")

    // No throw, no crash — both rename and copy+delete fail silently and the
    // error is logged. The call itself returns without raising.
    let logger = Logger(subsystem: "test", category: "backup")
    BrokenFileBackup.moveAside(at: url, logger: logger)

    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(contents.isEmpty)
  }

  private static func temporaryDirectory() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("broken-backup-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }
}
