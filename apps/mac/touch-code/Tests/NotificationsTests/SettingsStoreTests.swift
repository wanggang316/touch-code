import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

@MainActor
struct SettingsStoreTests {
  @Test
  func loadOfMissingFileReturnsDefaults() throws {
    let url = Self.temporaryURL()
    let store = NotificationSettingsStore(fileURL: url)
    let loaded = try store.load()
    #expect(loaded == .default)
    #expect(store.settings == .default)
  }

  @Test
  func saveAndLoadRoundTripsMuteSettings() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = NotificationSettingsStore(fileURL: url, debounce: .milliseconds(1))
    store.mutate { settings in
      settings.notifications.mute.surfaceIdle = true
      settings.notifications.mute.mutedRuleIDs.insert("claude.completed")
      settings.notifications.neverPrompt = true
    }
    try store.saveNow()

    let fresh = NotificationSettingsStore(fileURL: url)
    let loaded = try fresh.load()
    #expect(loaded.notifications.mute.surfaceIdle == true)
    #expect(loaded.notifications.mute.mutedRuleIDs.contains("claude.completed"))
    #expect(loaded.notifications.neverPrompt == true)
  }

  @Test
  func unknownVersionIsBackedUp() throws {
    let dir = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try Data(#"{"version": 42}"#.utf8).write(to: url)

    let store = NotificationSettingsStore(fileURL: url)
    _ = try store.load()
    #expect(store.settings == .default)

    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(contents.contains(where: { $0.hasPrefix("settings.json.broken-") }))
  }

  @Test
  func authStatusCacheRoundTrip() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = NotificationSettingsStore(fileURL: url)
    store.mutate { settings in
      settings.notifications.authStatus = .denied
    }
    try store.saveNow()

    let fresh = NotificationSettingsStore(fileURL: url)
    let loaded = try fresh.load()
    #expect(loaded.notifications.authStatus == .denied)
  }

  private static func temporaryDirectory() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-settings-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private static func temporaryURL() -> URL {
    temporaryDirectory().appendingPathComponent("settings.json")
  }
}
