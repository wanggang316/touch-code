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
    #expect(store.settings.projects.isEmpty)
  }

  @Test
  func freshStoreSeededWithCatalogOverridesPersists() throws {
    // Regression guard: first-launch path where settings.json does not exist yet but
    // catalog.json still carries legacy v1 overrides (drained into the map before
    // SettingsStore init). Without the seed-and-persist branch the next launch would
    // see settings.json-still-missing + catalog.json-already-v2 → data lost forever.
    let url = FileManager.default.temporaryDirectory.appending(
      component: "settings-fresh-seed-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let pid = ProjectID()
    let overrides: SettingsMigration.CatalogOverrides = [
      pid: (defaultEditor: "vscode", worktreesDirectory: "/Users/x/wt")
    ]
    let store = SettingsStore(fileURL: url, catalogOverrides: overrides)
    #expect(store.settings.projects[pid]?.defaultEditor == "vscode")
    #expect(store.settings.projects[pid]?.worktreesDirectory == "/Users/x/wt")

    store.flush()
    let reloaded = SettingsStore(fileURL: url)  // no overrides this round
    #expect(reloaded.settings.projects[pid]?.defaultEditor == "vscode")
    #expect(reloaded.settings.projects[pid]?.worktreesDirectory == "/Users/x/wt")
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

  // C8a: the customEditor persistence tests retired along with the feature. The
  // `general.defaultEditorID` round-trip and load-path migration coverage above are the
  // successors; deeper value-domain migration lives in `TouchCodeCoreTests/EditorMigrationTests`.

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

    // Inject `"SENTINEL"` + `"A"` into `knownEditorIDs` so garbageCollectEditors doesn't
    // wipe either value on load — the test is about save-cancellation, not editor GC.
    let reloaded = SettingsStore(fileURL: url, knownEditorIDs: ["A", "SENTINEL"])
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
  func mutateProjectCreatesThenGCsEmptyEntryOnSave() throws {
    // An unchanged `ProjectSettings` entry is effectively empty and must be dropped on the
    // next save. Verifies the garbage-collect path wired into scheduleSave + saveNow.
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let projectID = ProjectID()
    store.mutateProject(projectID) { _ in }
    #expect(store.settings.projects[projectID] != nil, "in-memory state holds the entry pre-save")
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.projects[projectID] == nil, "empty entry should be GC'd on save")
  }

  @Test
  func mutateProjectPersistsNonEmptyEntry() throws {
    // A populated entry must round-trip through the save pipeline — including the nested
    // `git` subtree. Uses `defaultEditor` + a GitHub override to exercise both top-level
    // and nested fields.
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let projectID = ProjectID()
    store.mutateProject(projectID) {
      $0.defaultEditor = "vscode"
      $0.git = GitProjectSettings(defaultMergeStrategy: .squash)
    }
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    let entry = try #require(reloaded.settings.projects[projectID])
    #expect(entry.defaultEditor == "vscode")
    #expect(entry.git?.defaultMergeStrategy == .squash)
  }

  @Test
  func mutateProjectCollapsesEmptyGitChildBeforeSave() throws {
    // Setting then clearing the only git-field should collapse `git` to nil on save,
    // matching the omit-when-default encoding contract.
    let (store, url) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let projectID = ProjectID()
    store.mutateProject(projectID) {
      $0.defaultEditor = "vscode"
      $0.git = GitProjectSettings()  // effectively empty
    }
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    let entry = try #require(reloaded.settings.projects[projectID])
    #expect(entry.defaultEditor == "vscode")
    #expect(entry.git == nil, "empty git subtree should collapse to nil on save")
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

    // Inject `"initial"` into `knownEditorIDs` so `garbageCollectEditors` does not wipe the
    // sentinel — the test isolates write-failure behaviour, not editor-ID normalisation.
    let store = SettingsStore(
      fileURL: url,
      debounceWindow: .milliseconds(1),
      knownEditorIDs: ["initial"]
    )
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
