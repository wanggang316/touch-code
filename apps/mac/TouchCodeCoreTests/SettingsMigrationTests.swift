import Foundation
import Testing

@testable import TouchCodeCore

struct SettingsMigrationTests {
  @Test
  func missingFileReturnsFresh() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }
    #expect(try SettingsMigration.load(from: harness.fileURL) == .fresh)
  }

  @Test
  func migratesEditorOnlyV1() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let json = #"""
      {
        "version": 1,
        "defaultEditorID": "vscode",
        "customEditors": [
          { "id": "helix", "displayName": "Helix",
            "template": { "binary": "hx", "args": ["{dir}"] } }
        ]
      }
      """#
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV1(let settings, let backupURL) = outcome else {
      Issue.record("Expected .migratedFromV1, got \(outcome)")
      return
    }

    #expect(settings.version == Settings.currentVersion)
    #expect(settings.general.defaultEditorID == "vscode")
    #expect(settings.general.customEditors.count == 1)
    #expect(settings.general.customEditors.first?.id == "helix")
    #expect(settings.notifications == .default)
    #expect(settings.developer == .default)
    #expect(settings.repositories.isEmpty)
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.v1-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    #expect(!FileManager.default.fileExists(atPath: harness.fileURL.path))
  }

  @Test
  func migratesNotificationsOnlyV1() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let json = #"""
      {
        "version": 1,
        "notifications": {
          "mute": {
            "enabled": true,
            "badgeEnabled": false,
            "surfaceIdle": false,
            "redactBodies": false,
            "mutedRuleIDs": ["noisy-rule"],
            "mutedPanelIDs": []
          },
          "authStatus": "denied",
          "neverPrompt": true,
          "notNowUntil": null
        }
      }
      """#
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV1(let settings, _) = outcome else {
      Issue.record("Expected .migratedFromV1, got \(outcome)")
      return
    }

    #expect(settings.notifications.mute.mutedRuleIDs == ["noisy-rule"])
    #expect(settings.notifications.authStatus == .denied)
    #expect(settings.notifications.neverPrompt == true)
    #expect(settings.notifications.dockBadgeEnabled == false, "v1 mute.badgeEnabled=false must carry into dockBadgeEnabled")
    #expect(settings.general == .default)
  }

  @Test
  func migratesCombinedV1() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let json = #"""
      {
        "version": 1,
        "defaultEditorID": "zed",
        "customEditors": [],
        "notifications": {
          "mute": {
            "enabled": true,
            "badgeEnabled": true,
            "surfaceIdle": false,
            "redactBodies": false,
            "mutedRuleIDs": [],
            "mutedPanelIDs": []
          },
          "authStatus": "authorized",
          "neverPrompt": false
        }
      }
      """#
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV1(let settings, _) = outcome else {
      Issue.record("Expected .migratedFromV1, got \(outcome)")
      return
    }

    #expect(settings.general.defaultEditorID == "zed")
    #expect(settings.notifications.authStatus == .authorized)
    #expect(settings.notifications.dockBadgeEnabled == true)
  }

  @Test
  func backsUpUnsupportedVersion() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    try Data(#"{"version":99}"#.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .unsupported(let version, let backupURL) = outcome else {
      Issue.record("Expected .unsupported, got \(outcome)")
      return
    }
    #expect(version == 99)
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.broken-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
  }

  @Test
  func backsUpCorruptJSON() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    try Data(#"{ broken"#.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .corrupt(let backupURL) = outcome else {
      Issue.record("Expected .corrupt, got \(outcome)")
      return
    }
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.broken-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
  }

  @Test
  func v2FilePassesThroughUnmodified() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let fixture = Settings(
      version: Settings.currentVersion,
      general: GeneralSettings(defaultEditorID: "cursor"),
      notifications: .default,
      developer: .default,
      repositories: [:]
    )
    try JSONEncoder.touchCodeDefault.encode(fixture).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .v2(let settings) = outcome else {
      Issue.record("Expected .v2, got \(outcome)")
      return
    }
    #expect(settings == fixture)
    // v2 passthrough must NOT move the original aside.
    #expect(FileManager.default.fileExists(atPath: harness.fileURL.path))
  }
}

// MARK: - Harness

private final class MigrationHarness {
  let directory: URL
  var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }
  let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_777_190_400) }  // 2026-04-26

  init() {
    self.directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SettingsMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
