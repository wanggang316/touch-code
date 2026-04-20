import Foundation
import Observation
import TouchCodeCore
import os.log

/// `@MainActor @Observable` owner of `~/.config/touch-code/settings.json`. Mirrors the
/// `CatalogStore` pattern: atomic-rename writes via `AtomicFileStore`, 500 ms trailing
/// debounce on structural mutations, broken-file backup on decode failure.
///
/// Mutations happen through the exposed methods (never direct property assignment) so the
/// debounced save is always armed. Views subscribe through the `@Observable` surface.
@MainActor
@Observable
final class SettingsStore {
  private(set) var settings: Settings

  private let fileURL: URL
  private let logger = Logger(subsystem: "com.touch-code.persistence", category: "settings")
  @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
  @ObservationIgnored private let debounceWindow: Duration

  /// Production debounce window between a mutation and the atomic-rename write. Matches
  /// `CatalogStore`. Tests inject a shorter window via the initializer.
  static let debounceWindow: Duration = .milliseconds(500)

  init(
    fileURL: URL = Settings.defaultURL(),
    debounceWindow: Duration = SettingsStore.debounceWindow
  ) {
    self.fileURL = fileURL
    self.debounceWindow = debounceWindow
    if let existing = Self.safeLoad(from: fileURL, logger: logger) {
      self.settings = existing
    } else {
      self.settings = .default
    }
  }

  // MARK: - Mutations

  func setDefaultEditorID(_ id: EditorID?) {
    settings.defaultEditorID = id
    scheduleSave()
  }

  /// Adds a custom editor. Validates the template and the ID. Returns `false` if validation
  /// failed (caller can surface a UI error without a thrown-error propagation chain through
  /// SwiftUI).
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
    // Reject collisions with built-ins.
    let builtinIDs = Set(EditorRegistry.builtins.map(\.id))
    if builtinIDs.contains(editor.id) {
      return .failure(.invalidID(editor.id))
    }
    // Replace on ID collision with an existing custom (upsert semantics; avoids duplicate IDs).
    if let idx = settings.customEditors.firstIndex(where: { $0.id == editor.id }) {
      settings.customEditors[idx] = editor
    } else {
      settings.customEditors.append(editor)
    }
    scheduleSave()
    return .success(())
  }

  @discardableResult
  func updateCustomEditor(id: EditorID, _ transform: (inout CustomEditor) -> Void) -> Bool {
    guard let idx = settings.customEditors.firstIndex(where: { $0.id == id }) else { return false }
    transform(&settings.customEditors[idx])
    // Revalidate in case the transform mutated the template or ID.
    do {
      _ = try CustomEditor.validatedID(settings.customEditors[idx].id)
      try settings.customEditors[idx].template.validate()
    } catch {
      // Revert on invalid transform — avoids persisting a broken state.
      logger.error("updateCustomEditor rejected invalid transform: \(String(describing: error), privacy: .public)")
      return false
    }
    scheduleSave()
    return true
  }

  @discardableResult
  func removeCustomEditor(id: EditorID) -> Bool {
    let before = settings.customEditors.count
    settings.customEditors.removeAll { $0.id == id }
    let changed = settings.customEditors.count != before
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
    try AtomicFileStore.write(settings, to: fileURL)
  }

  /// Cancels any pending debounced write and flushes immediately. Callers:
  /// `applicationWillTerminate`, explicit user Save, test teardown.
  func flush() {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    do {
      try saveNow()
    } catch {
      logger.error("Failed to flush settings: \(String(describing: error), privacy: .public)")
    }
  }

  private func scheduleSave() {
    pendingSaveTask?.cancel()
    let snapshot = settings
    pendingSaveTask = Task { [weak self] in
      // Use the instance window so tests can shorten it to milliseconds.
      let window = self?.debounceWindow ?? Self.debounceWindow
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do {
        try AtomicFileStore.write(snapshot, to: self.fileURL)
      } catch {
        // Log and leave the existing file untouched. Transient disk-full /
        // permissions flips shouldn't cost the user their persisted settings;
        // the next successful save will pick up the in-memory snapshot. Only
        // the load path (decode failure / unsupported version) moves corrupt
        // files aside — that's where a bad file blocks startup and needs
        // unsticking.
        self.logger.error("Failed to save settings: \(String(describing: error), privacy: .public)")
      }
    }
  }

  // MARK: - Load helper

  /// Best-effort load. Returns nil on file-missing or unrecoverable decode failure. Moves a
  /// corrupt file aside to `settings.json.broken-<YYYYMMDD-HHMMSS>` so the next launch
  /// starts from a clean default without blocking on repair.
  private static func safeLoad(from url: URL, logger: Logger) -> Settings? {
    do {
      return try AtomicFileStore.read(Settings.self, at: url)
    } catch let Settings.DecodingIssue.unsupportedVersion(version) {
      logger.error("Settings file has unsupported version \(version, privacy: .public); backing up")
      moveAside(url: url, timestamp: filesystemSafeTimestamp())
      return nil
    } catch {
      logger.error("Failed to decode settings: \(String(describing: error), privacy: .public); backing up")
      moveAside(url: url, timestamp: filesystemSafeTimestamp())
      return nil
    }
  }

  private static func moveAside(url: URL, timestamp: String) {
    let backupURL = url.deletingLastPathComponent()
      .appendingPathComponent("settings.json.broken-\(timestamp)")
    try? FileManager.default.moveItem(at: url, to: backupURL)
  }

  /// `yyyyMMdd-HHmmss` — filesystem-safe across case-insensitive and ':'-averse tooling.
  /// ISO-8601 with its `:` separators confuses some backup + archive utilities.
  private static func filesystemSafeTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}
