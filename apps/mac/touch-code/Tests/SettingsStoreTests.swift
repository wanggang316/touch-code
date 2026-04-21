import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Round-trip + validation tests for `SettingsStore` (v2). Uses `flush()` to bypass the
/// 500 ms debounce and commit immediately to disk so we can re-read the file in the same
/// test. Migration-path coverage lives in `SettingsMigrationTests`; this suite focuses on
/// the mutate API, reader conformance, and persistence coalescing.
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
    #expect(store.settings.general.defaultEditorID == nil)
    #expect(store.settings.general.customEditors.isEmpty)
    #expect(store.settings.repositories.isEmpty)
  }

  @Test
  func setDefaultEditorIDRoundTrips() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.setDefaultEditorID("vscode")
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.general.defaultEditorID == "vscode")
  }

  @Test
  func clearDefaultEditorIDRoundTrips() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.setDefaultEditorID("zed")
    store.setDefaultEditorID(nil)
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.general.defaultEditorID == nil)
  }

  @Test
  func setAppearanceRoundTrips() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.setAppearance(.dark)
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.general.appearance == .dark)
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
    #expect(reloaded.settings.general.customEditors.count == 1)
    #expect(reloaded.settings.general.customEditors.first?.id == "helix")
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
    #expect(store.settings.general.customEditors.isEmpty)
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
    #expect(store.settings.general.customEditors.count == 1)
    #expect(store.settings.general.customEditors.first?.displayName == "Helix Nightly")
    #expect(store.settings.general.customEditors.first?.template.binary == "hx-nightly")
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
    #expect(reloaded.settings.general.customEditors.isEmpty)
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
    #expect(store.settings.general.customEditors.first?.displayName == "Helix (renamed)")
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
    // PR #22 review N3: the rejected transform must not have leaked into in-memory state.
    // Without the revert, the broken template would persist on the next scheduled save.
    #expect(store.settings.general.customEditors.first == entry)
  }

  @Test
  func saveNowCancelsPendingDebouncedWrite() async throws {
    // PR #22 review N6: saveNow must cancel the in-flight debounced task so a stale
    // snapshot can't clobber the file after saveNow returns.
    //
    // Strategy: schedule a save of "A" with a short debounce window, call saveNow (which
    // writes "A" and should cancel the pending task), then overwrite the file externally
    // with a SENTINEL value and wait past the debounce fire time. If saveNow had left the
    // pending task alive, it would fire and overwrite the SENTINEL with "A"; if saveNow
    // cancelled as contracted, the SENTINEL survives.
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-savenow-cancel-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SettingsStore(fileURL: url, debounceWindow: .milliseconds(50))
    store.setDefaultEditorID("A")  // schedules a debounced save of snapshot{defaultEditorID="A"}
    try store.saveNow()  // writes "A", must also cancel the pending task

    // External write that bypasses the store entirely. After this call the file contains
    // SENTINEL; if the cancelled task were to fire, it would overwrite back to "A".
    var sentinel = Settings.default
    sentinel.general.defaultEditorID = "SENTINEL"
    try AtomicFileStore.write(sentinel, to: url)

    // Wait comfortably past the debounce window so any surviving task has fired.
    try await Task.sleep(for: .milliseconds(200))

    let reloaded = SettingsStore(fileURL: url)
    #expect(
      reloaded.settings.general.defaultEditorID == "SENTINEL",
      "saveNow must cancel pendingSaveTask; surviving task would have written 'A' on top of SENTINEL")
  }

  @Test
  func mutateNotificationsWritesToDisk() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.mutateNotifications {
      $0.authStatus = .authorized
      $0.inAppEnabled = false
    }
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.notifications.authStatus == .authorized)
    #expect(reloaded.settings.notifications.inAppEnabled == false)
  }

  @Test
  func mutateDeveloperWritesToDisk() throws {
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    store.mutateDeveloper { $0.cli.lastInstallAttemptAt = stamp }
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.developer.cli.lastInstallAttemptAt == stamp)
  }

  @Test
  func mutateRepositoryCreatesThenGCsEmptyEntryOnSave() throws {
    // RepositorySettings is reserved-empty in T1 (design D1), so any entry the caller touches
    // is effectively empty and must be dropped on the next save. Verifies the gc path wired
    // into scheduleSave + saveNow.
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let projectID = ProjectID()
    store.mutateRepository(projectID) { _ in }
    #expect(store.settings.repositories[projectID] != nil, "in-memory state holds the entry pre-save")
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.repositories[projectID] == nil, "empty entry should be GC'd on save")
  }

  @Test
  func conformsToNotificationSettingsReader() {
    let (store, _) = makeStore()
    // Reader surface reads through to the live `settings.notifications` sub-tree.
    let reader: any NotificationSettingsReader = store
    #expect(reader.authStatus == .notDetermined)
    #expect(reader.inAppEnabled == true)

    store.mutateNotifications {
      $0.inAppEnabled = false
      $0.neverPrompt = true
    }
    #expect(reader.inAppEnabled == false)
    #expect(reader.neverPrompt == true)
  }

  @Test
  func rapidMutationsCoalesceIntoSingleWrite() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-coalesce-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SettingsStore(fileURL: url, debounceWindow: .milliseconds(25))

    store.setDefaultEditorID("vscode")
    store.setDefaultEditorID("cursor")
    store.setDefaultEditorID("zed")

    #expect(!FileManager.default.fileExists(atPath: url.path))
    try await Task.sleep(for: .milliseconds(75))

    #expect(FileManager.default.fileExists(atPath: url.path))
    let reloaded = SettingsStore(fileURL: url)
    #expect(
      reloaded.settings.general.defaultEditorID == "zed",
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
    let parent = FileManager.default.temporaryDirectory.appending(
      component: "settings-writefail-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let url = parent.appending(component: "settings.json")
    try AtomicFileStore.write(
      Settings(general: GeneralSettings(defaultEditorID: "initial")),
      to: url
    )

    let store = SettingsStore(fileURL: url, debounceWindow: .milliseconds(1))
    #expect(store.settings.general.defaultEditorID == "initial")

    // Swap the target for a non-empty directory so subsequent rename(temp, url) fails.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try "keep".write(
      to: url.appending(component: "keep.txt"),
      atomically: true,
      encoding: .utf8
    )

    store.setDefaultEditorID("changed")
    store.flush()

    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
    #expect(isDir.boolValue, "pre-existing directory should be preserved on write failure")

    let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(
      !siblings.contains(where: { $0.hasPrefix("settings.json.broken-") }),
      "write-failure path must not create a .broken-* sibling; got siblings=\(siblings)"
    )
  }

  @Test
  func migratesV1EditorFileOnInit() throws {
    // End-to-end check of the load path: a pre-v2 file on disk must be migrated to v2 and a
    // backup must appear next to it. Detailed migration cases live in SettingsMigrationTests;
    // this test just proves SettingsStore.init actually invokes the migration.
    let parent = FileManager.default.temporaryDirectory.appending(
      component: "settings-v1-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let url = parent.appending(component: "settings.json")
    let v1 = #"""
      { "version": 1, "defaultEditorID": "cursor", "customEditors": [] }
      """#
    try v1.write(to: url, atomically: true, encoding: .utf8)

    let store = SettingsStore(fileURL: url)
    #expect(store.settings.general.defaultEditorID == "cursor")

    let siblings = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(siblings.contains(where: { $0.hasPrefix("settings.json.v1-") }))
  }
}

extension Result where Success == Void {
  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}
