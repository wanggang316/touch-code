import Foundation
import Observation
import TouchCodeCore
import os.log

/// `@MainActor @Observable` owner of `~/.config/touch-code/settings.json` (v2). Single writer
/// for the file — the former `NotificationSettingsStore` is deleted in this step. Mirrors the
/// `CatalogStore` pattern: atomic-rename writes via `AtomicFileStore`, 500 ms trailing
/// debounce on structural mutations, broken-file backup on decode failure. On first launch
/// after the v1→v2 transition, any pre-v2 `settings.json` is routed through
/// `SettingsMigration.load` and its original is preserved as `settings.json.v1-<ts>`.
///
/// Mutations go through section-scoped `mutate*` closures or the editor-specific
/// convenience methods; direct property assignment is not exposed. Views subscribe through
/// the `@Observable` surface. Notifications consumers read through the
/// `NotificationSettingsReader` conformance and write through `mutateNotifications`.
@MainActor
@Observable
final class SettingsStore {
  private(set) var settings: Settings

  private let fileURL: URL
  private let logger = Logger(subsystem: "com.touch-code.persistence", category: "settings")
  @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
  @ObservationIgnored private let debounceWindow: Duration
  /// `false` when migration returned `.migrationBackupFailed` — the original settings.json
  /// is still at the canonical URL and must not be overwritten. In this state all mutate
  /// APIs still work in-memory but `scheduleSave` / `saveNow` / `flush` become no-ops.
  @ObservationIgnored private var persistenceEnabled: Bool = true

  /// Production debounce window between a mutation and the atomic-rename write. Matches
  /// `CatalogStore`. Tests inject a shorter window via the initializer.
  static let debounceWindow: Duration = .milliseconds(500)

  init(
    fileURL: URL = Settings.defaultURL(),
    debounceWindow: Duration = SettingsStore.debounceWindow
  ) {
    self.fileURL = fileURL
    self.debounceWindow = debounceWindow
    // `migrationSafeToPersist` gates every subsequent save attempt. When the migration
    // helper returns `.migrationBackupFailed`, the original v1 file may still be sitting at
    // the canonical URL — writing on top of it would destroy the user's historical data.
    // Setting the flag to false puts the store into a read-only / in-memory-only mode.
    var safeToPersist = true

    do {
      switch try SettingsMigration.load(from: fileURL) {
      case .fresh:
        self.settings = .default
      case .v2(let existing):
        self.settings = existing
      case .migratedFromV1(_, let backupURL):
        // Migration already committed both the new canonical file and the backup durably —
        // we just read the migrated tree back from disk so the in-memory copy matches what
        // the next launch will see.
        let persisted = (try? AtomicFileStore.read(Settings.self, at: fileURL)) ?? nil
        if let persisted {
          self.settings = persisted
          logger.info("Loaded migrated v2 settings.json (backup: \(backupURL.lastPathComponent, privacy: .public))")
        } else {
          // Extraordinarily unlikely: migration claimed success but the file isn't readable.
          // Treat as unsafe — don't overwrite whatever IS on disk.
          logger.error("Migration reported success but settings.json is not readable; refusing to persist")
          self.settings = .default
          safeToPersist = false
        }
      case .unsupported(let version, let backupURL):
        logger.error(
          "settings.json had unsupported version \(version, privacy: .public); starting defaults (backup: \(backupURL.lastPathComponent, privacy: .public))"
        )
        self.settings = .default
      case .corrupt(let backupURL):
        logger.error(
          "settings.json was unparseable; starting defaults (backup: \(backupURL.lastPathComponent, privacy: .public))"
        )
        self.settings = .default
      case .migrationBackupFailed(let description):
        // The original file is still at the canonical URL (or was restored there). Do NOT
        // persist anything on top of it — the user's data is intact and takes precedence
        // over the in-memory defaults until a human intervenes.
        logger.error(
          "settings.json migration could not preserve original atomically: \(description, privacy: .public); starting defaults in read-only mode"
        )
        self.settings = .default
        safeToPersist = false
      }
    } catch {
      logger.error(
        "SettingsMigration.load failed with \(String(describing: error), privacy: .public); starting defaults in read-only mode"
      )
      self.settings = .default
      safeToPersist = false
    }
    self.persistenceEnabled = safeToPersist
  }

  // MARK: - Section mutators

  func mutateGeneral(_ transform: (inout GeneralSettings) -> Void) {
    transform(&settings.general)
    scheduleSave()
  }

  func mutateNotifications(_ transform: (inout NotificationsSettings) -> Void) {
    transform(&settings.notifications)
    scheduleSave()
  }

  func mutateDeveloper(_ transform: (inout DeveloperSettings) -> Void) {
    transform(&settings.developer)
    scheduleSave()
  }

  /// Mutates the `RepositorySettings` for `projectID`, creating an empty entry if none
  /// exists. The pre-save garbage collection in `scheduleSave` drops any entry that ends up
  /// effectively empty so `settings.json` never accumulates useless `{}` objects.
  func mutateRepository(
    _ projectID: ProjectID,
    _ transform: (inout RepositorySettings) -> Void
  ) {
    var entry = settings.repositories[projectID] ?? RepositorySettings()
    transform(&entry)
    settings.repositories[projectID] = entry
    scheduleSave()
  }

  // MARK: - Editor convenience (legacy surface kept for SettingsWriter)

  func setDefaultEditorID(_ id: EditorID?) {
    settings.general.defaultEditorID = id
    scheduleSave()
  }

  func setAppearance(_ appearance: AppearancePreference) {
    settings.general.appearance = appearance
    scheduleSave()
  }

  @discardableResult
  func addCustomEditor(_ editor: CustomEditor) -> Result<Void, EditorTemplateError> {
    do {
      _ = try CustomEditor.validatedID(editor.id)
      try editor.template.validate()
    } catch let error as EditorTemplateError {
      return .failure(error)
    } catch {
      return .failure(.invalidID(editor.id))
    }
    let builtinIDs = Set(EditorRegistry.builtins.map(\.id))
    if builtinIDs.contains(editor.id) {
      return .failure(.invalidID(editor.id))
    }
    if let idx = settings.general.customEditors.firstIndex(where: { $0.id == editor.id }) {
      settings.general.customEditors[idx] = editor
    } else {
      settings.general.customEditors.append(editor)
    }
    scheduleSave()
    return .success(())
  }

  @discardableResult
  func updateCustomEditor(id: EditorID, _ transform: (inout CustomEditor) -> Void) -> Bool {
    guard let idx = settings.general.customEditors.firstIndex(where: { $0.id == id }) else { return false }
    transform(&settings.general.customEditors[idx])
    do {
      _ = try CustomEditor.validatedID(settings.general.customEditors[idx].id)
      try settings.general.customEditors[idx].template.validate()
    } catch {
      logger.error("updateCustomEditor rejected invalid transform: \(String(describing: error), privacy: .public)")
      return false
    }
    scheduleSave()
    return true
  }

  @discardableResult
  func removeCustomEditor(id: EditorID) -> Bool {
    let before = settings.general.customEditors.count
    settings.general.customEditors.removeAll { $0.id == id }
    let changed = settings.general.customEditors.count != before
    if changed { scheduleSave() }
    return changed
  }

  /// Hard-overwrite the entire settings document. Only used by tests and recovery paths.
  func replaceAll(_ new: Settings) {
    settings = new
    scheduleSave()
  }

  // MARK: - Persistence

  func saveNow() throws {
    guard persistenceEnabled else {
      logger.error("saveNow skipped: persistence disabled (migration did not complete atomically)")
      return
    }
    // Cancel any pending debounced save BEFORE writing so the in-flight task can't clobber
    // us with a stale snapshot after this call returns. Matches PR #22 review N6.
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    settings.garbageCollect()
    try AtomicFileStore.write(settings, to: fileURL)
  }

  /// Cancels any pending debounced write and flushes immediately. Callers:
  /// `applicationWillTerminate`, explicit user Save, test teardown.
  func flush() {
    do {
      try saveNow()
    } catch {
      logger.error("Failed to flush settings: \(String(describing: error), privacy: .public)")
    }
  }

  private func scheduleSave() {
    guard persistenceEnabled else {
      logger.debug("scheduleSave skipped: persistence disabled (migration did not complete atomically)")
      return
    }
    pendingSaveTask?.cancel()
    var snapshot = settings
    snapshot.garbageCollect()
    pendingSaveTask = Task { [weak self] in
      let window = self?.debounceWindow ?? Self.debounceWindow
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do {
        try AtomicFileStore.write(snapshot, to: self.fileURL)
      } catch {
        // Log and leave the existing file untouched. Transient disk-full / permissions flips
        // shouldn't cost the user their persisted settings; the next successful save picks up
        // the in-memory snapshot. Only the load path moves corrupt files aside.
        self.logger.error("Failed to save settings: \(String(describing: error), privacy: .public)")
      }
    }
  }
}

// MARK: - NotificationSettingsReader

extension SettingsStore: NotificationSettingsReader {
  var mute: MuteSettings { settings.notifications.mute }
  var authStatus: AuthorizationStatusCache { settings.notifications.authStatus }
  var neverPrompt: Bool { settings.notifications.neverPrompt }
  var notNowUntil: Date? { settings.notifications.notNowUntil }
  var inAppEnabled: Bool { settings.notifications.inAppEnabled }
  var systemEnabled: Bool { settings.notifications.systemEnabled }
  var soundEnabled: Bool { settings.notifications.soundEnabled }
  var dockBadgeEnabled: Bool { settings.notifications.dockBadgeEnabled }
}
