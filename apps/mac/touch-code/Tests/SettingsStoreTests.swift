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
  func rapidMutationsCoalesceIntoSingleWrite() async throws {
    // Short debounce so the test stays quick but still exercises the coalescing path.
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-coalesce-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SettingsStore(fileURL: url, debounceWindow: .milliseconds(25))

    // Three rapid mutations: each cancels the prior task. Only the last snapshot
    // should reach disk.
    store.setDefaultEditorID("vscode")
    store.setDefaultEditorID("cursor")
    store.setDefaultEditorID("zed")

    // File must not exist yet — debounce hasn't fired.
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // Wait for the debounced write.
    try await Task.sleep(for: .milliseconds(75))

    #expect(FileManager.default.fileExists(atPath: url.path))
    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.defaultEditorID == "zed",
            "only the last mutation should have been persisted; debounce failed to coalesce")
  }

  @Test
  func flushBypassesDebounce() throws {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-flush-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SettingsStore(fileURL: url, debounceWindow: .seconds(60))
    store.setDefaultEditorID("vscode")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    store.flush()
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func writeFailureLogsButDoesNotMoveFileAside() throws {
    // Reproducing the specific write-failure branch: let the store load normally, THEN
    // swap the target URL for a non-empty directory so the subsequent atomic-rename trips
    // ENOTEMPTY. The load path already handles corrupt/directory inputs by moving them
    // aside (that's a separate code path). This test proves the write path does not.
    let parent = FileManager.default.temporaryDirectory.appending(
      component: "settings-writefail-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let url = parent.appending(component: "settings.json")
    // Seed a valid initial settings file so the store loads cleanly.
    try AtomicFileStore.write(
      Settings(defaultEditorID: "initial"),
      to: url
    )

    let store = SettingsStore(fileURL: url, debounceWindow: .milliseconds(1))
    #expect(store.settings.defaultEditorID == "initial")

    // Swap the target for a non-empty directory. Any future rename(temp, url) will fail
    // with ENOTEMPTY because the "dest already exists and is non-empty" case.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try "keep".write(
      to: url.appending(component: "keep.txt"),
      atomically: true,
      encoding: .utf8
    )

    // Mutate + flush. The write inside flush() must swallow the error silently (logs only).
    store.setDefaultEditorID("changed")
    store.flush()

    // The directory we placed must still be there — write failure must not rename it away.
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    #expect(isDir.boolValue, "pre-existing directory should be preserved on write failure")

    // No broken-* sibling should have been created by the write path.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(
      !siblings.contains(where: { $0.hasPrefix("settings.json.broken-") }),
      "write-failure path must not create a .broken-* sibling; got siblings=\(siblings)"
    )
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
