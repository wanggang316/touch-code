import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct ShortcutsStoreTests {
  @Test
  func emptyFileLoadsEmptyOverrides() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(store.overrides.overrides.isEmpty)
    #expect(store.resolved.count == CommandID.allCases.count)
  }

  @Test
  func updateThenSaveNowPersistsOverride() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    let custom = ShortcutBinding(keyCode: 17, modifiers: [.command, .control])
    store.update(.newTab, to: custom)
    try store.saveNow()

    let reread = try AtomicFileStore.read(ShortcutOverrideStore.self, at: url)
    #expect(reread?.overrides[.newTab] == custom)
  }

  @Test
  func roundTripAcrossInstances() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let custom = ShortcutBinding(keyCode: 5, modifiers: [.command, .shift])
    let writer = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    writer.update(.toggleGitViewer, to: custom)
    writer.flush()

    let reader = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(reader.overrides.overrides[.toggleGitViewer] == custom)
    #expect(reader.resolved[.toggleGitViewer]?.binding == custom)
    #expect(reader.resolved[.toggleGitViewer]?.source == .userOverride)
  }

  @Test
  func disablePreservesBindingButFlipsEnabledFlag() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    store.disable(.toggleGitViewer)
    try store.saveNow()

    let entry = store.overrides.overrides[.toggleGitViewer]
    let schemaDefault = ShortcutSchema.app.entry(for: .toggleGitViewer)?.defaultBinding
    #expect(entry?.keyCode == schemaDefault?.keyCode)
    #expect(entry?.modifiers == schemaDefault?.modifiers)
    #expect(entry?.isEnabled == false)

    #expect(store.resolved[.toggleGitViewer]?.isEnabled == false)
  }

  @Test
  func clearRevertsToSchemaDefault() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    store.update(.newTab, to: .init(keyCode: 99, modifiers: .command))
    store.clear(.newTab)

    #expect(store.overrides.overrides[.newTab] == nil)
    let schemaDefault = ShortcutSchema.app.entry(for: .newTab)?.defaultBinding
    #expect(store.resolved[.newTab]?.binding == schemaDefault)
    #expect(store.resolved[.newTab]?.source == .schemaDefault)
  }

  @Test
  func resetAllDropsEveryOverride() {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    store.update(.newTab, to: .init(keyCode: 17, modifiers: .command))
    store.update(.toggleGitViewer, to: .init(keyCode: 5, modifiers: .command))
    store.resetAll()

    #expect(store.overrides.overrides.isEmpty)
  }

  @Test
  func brokenFileIsBackedUpAndStoreStartsEmpty() throws {
    let url = Self.temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: url)
      try? Self.cleanUpBackups(siblingOf: url)
    }

    try Data("not json".utf8).write(to: url)

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(store.overrides.overrides.isEmpty)

    let backups = Self.findBackups(siblingOf: url)
    #expect(!backups.isEmpty, "Expected a `shortcuts.json.broken-*` backup beside the canonical URL.")
  }

  @Test
  func unsupportedVersionIsBackedUp() throws {
    let url = Self.temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: url)
      try? Self.cleanUpBackups(siblingOf: url)
    }

    let payload = Data(#"{"version": 99, "overrides": {}}"#.utf8)
    try payload.write(to: url)

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(10))
    #expect(store.overrides.overrides.isEmpty)

    let backups = Self.findBackups(siblingOf: url)
    #expect(!backups.isEmpty)
  }

  @Test
  func debounceCoalescesBurstIntoOneWrite() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = ShortcutsStore(fileURL: url, debounceWindow: .milliseconds(80))

    store.update(.newTab, to: .init(keyCode: 1, modifiers: .command))
    store.update(.newTab, to: .init(keyCode: 2, modifiers: .command))
    let final = ShortcutBinding(keyCode: 3, modifiers: .command)
    store.update(.newTab, to: final)

    // File should not exist yet — all three writes are pending behind one debounce window.
    #expect(!FileManager.default.fileExists(atPath: url.path))

    try await Task.sleep(for: .milliseconds(200))

    let reread = try AtomicFileStore.read(ShortcutOverrideStore.self, at: url)
    #expect(reread?.overrides[.newTab] == final, "Last mutation should win after debounce.")
  }

  @Test
  func defaultURLPointsAtConfigDirectory() {
    let home = URL(fileURLWithPath: "/tmp/fake-home", isDirectory: true)
    let url = ShortcutsStore.defaultURL(home: home)
    #expect(url.path == "/tmp/fake-home/.config/touch-code/shortcuts.json")
  }

  // MARK: - Test helpers

  private static func temporaryURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shortcuts-store-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("shortcuts.json", isDirectory: false)
  }

  private static func findBackups(siblingOf url: URL) -> [URL] {
    let directory = url.deletingLastPathComponent()
    let prefix = "\(url.lastPathComponent).broken-"
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return entries
      .filter { $0.hasPrefix(prefix) }
      .map { directory.appendingPathComponent($0) }
  }

  private static func cleanUpBackups(siblingOf url: URL) throws {
    for backup in findBackups(siblingOf: url) {
      try? FileManager.default.removeItem(at: backup)
    }
  }
}
