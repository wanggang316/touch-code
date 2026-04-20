import Foundation
import Testing
import TouchCodeCore
@testable import touch_code

/// Round-trip + validation tests for `SettingsStore`. Uses `flush()` to bypass the 500 ms
/// debounce and commit immediately to disk so we can re-read the file in the same test.
@MainActor
struct SettingsStoreTests {
  private func makeStore() -> (SettingsStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-\(UUID().uuidString).json"
    )
    return (SettingsStore(fileURL: url), url)
  }

  @Test
  func freshStoreHasDefaultSettings() {
    let (store, _) = makeStore()
    #expect(store.settings == .default)
    #expect(store.settings.version == Settings.currentVersion)
    #expect(store.settings.defaultEditorID == nil)
    #expect(store.settings.customEditors.isEmpty)
  }

  @Test
  func setDefaultEditorIDRoundTrips() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.setDefaultEditorID("vscode")
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.defaultEditorID == "vscode")
  }

  @Test
  func clearDefaultEditorIDRoundTrips() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.setDefaultEditorID("zed")
    store.setDefaultEditorID(nil)
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.defaultEditorID == nil)
  }

  @Test
  func addCustomEditorPersistsAndSurvivesReload() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let helix = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    let result = store.addCustomEditor(helix)
    guard case .success = result else {
      Issue.record("unexpected add failure: \(result)")
      return
    }
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.customEditors.count == 1)
    #expect(reloaded.settings.customEditors.first?.id == "helix")
  }

  @Test
  func addCustomEditorRejectsBuiltinCollision() {
    let (store, _) = makeStore()
    let colliding = CustomEditor(
      id: "vscode",
      displayName: "Bad",
      template: CommandTemplate(binary: "code-insiders", args: ["{dir}"])
    )
    let result = store.addCustomEditor(colliding)
    guard case .failure(let error) = result else {
      Issue.record("expected failure, got success")
      return
    }
    #expect(error == .invalidID("vscode"))
    #expect(store.settings.customEditors.isEmpty)
  }

  @Test
  func addCustomEditorRejectsInvalidTemplate() {
    let (store, _) = makeStore()
    let invalid = CustomEditor(
      id: "bad-template",
      displayName: "Bad",
      template: CommandTemplate(binary: "", args: ["{dir}"])
    )
    let result = store.addCustomEditor(invalid)
    guard case .failure(let error) = result else {
      Issue.record("expected failure, got success")
      return
    }
    #expect(error == .emptyBinary)
  }

  @Test
  func addCustomEditorUpsertReplacesExisting() {
    let (store, _) = makeStore()
    let original = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    let updated = CustomEditor(
      id: "helix",
      displayName: "Helix Nightly",
      template: CommandTemplate(binary: "hx-nightly", args: ["{dir}"])
    )
    #expect(store.addCustomEditor(original).isSuccess)
    #expect(store.addCustomEditor(updated).isSuccess)
    #expect(store.settings.customEditors.count == 1)
    #expect(store.settings.customEditors.first?.displayName == "Helix Nightly")
    #expect(store.settings.customEditors.first?.template.binary == "hx-nightly")
  }

  @Test
  func removeCustomEditorReturnsFalseWhenMissing() {
    let (store, _) = makeStore()
    #expect(store.removeCustomEditor(id: "nonexistent") == false)
  }

  @Test
  func removeCustomEditorReturnsTrueAndPersists() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let entry = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    #expect(store.addCustomEditor(entry).isSuccess)
    #expect(store.removeCustomEditor(id: "helix") == true)
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.customEditors.isEmpty)
  }

  @Test
  func updateCustomEditorAppliesTransform() {
    let (store, _) = makeStore()
    let entry = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    #expect(store.addCustomEditor(entry).isSuccess)
    let ok = store.updateCustomEditor(id: "helix") { editor in
      editor.displayName = "Helix (renamed)"
    }
    #expect(ok)
    #expect(store.settings.customEditors.first?.displayName == "Helix (renamed)")
  }

  @Test
  func updateCustomEditorRejectsInvalidTransform() {
    let (store, _) = makeStore()
    let entry = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    #expect(store.addCustomEditor(entry).isSuccess)
    let ok = store.updateCustomEditor(id: "helix") { editor in
      editor.template = CommandTemplate(binary: "", args: ["{dir}"])
    }
    #expect(!ok)
  }

  @Test
  func corruptFileIsMovedAsideAndStoreStartsWithDefaults() throws {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-corrupt-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    // Write a deliberately broken JSON document.
    try "{ this is not valid JSON".write(to: url, atomically: true, encoding: .utf8)

    let store = SettingsStore(fileURL: url)
    #expect(store.settings == .default)

    // The broken file should be renamed aside with the .broken- prefix.
    let parent = url.deletingLastPathComponent()
    let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(siblings.contains(where: { $0.hasPrefix("settings.json.broken-") }))

    // Clean up backup.
    for name in siblings where name.hasPrefix("settings.json.broken-") {
      try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
    }
  }

  @Test
  func unsupportedVersionIsMovedAside() throws {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-wrongver-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let payload = """
      { "version": 999, "defaultEditorID": "vscode", "customEditors": [] }
      """
    try payload.write(to: url, atomically: true, encoding: .utf8)

    let store = SettingsStore(fileURL: url)
    // Fresh defaults — unsupported version never loads.
    #expect(store.settings == .default)

    let parent = url.deletingLastPathComponent()
    let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(siblings.contains(where: { $0.hasPrefix("settings.json.broken-") }))
    for name in siblings where name.hasPrefix("settings.json.broken-") {
      try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
    }
  }
}

private extension Result where Success == Void {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}
