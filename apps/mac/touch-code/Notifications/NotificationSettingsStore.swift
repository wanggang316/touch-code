import Foundation
import os.log
import TouchCodeCore

/// On-disk shape of `~/.config/touch-code/settings.json`. Only the
/// `notifications` sub-tree is populated in M4a; future features can add
/// sibling top-level keys without touching this file as long as they add
/// Codable properties and keep the version gate. Architecture invariant
/// (readers abort on unknown version) is honoured.
public nonisolated struct TouchCodeSettings: Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var notifications: NotificationsSettings

  public init(
    version: Int = TouchCodeSettings.currentVersion,
    notifications: NotificationsSettings = .init()
  ) {
    self.version = version
    self.notifications = notifications
  }

  public static let `default` = TouchCodeSettings()
}

extension TouchCodeSettings: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey { case version, notifications }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == TouchCodeSettings.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = version
    self.notifications = try container.decodeIfPresent(NotificationsSettings.self, forKey: .notifications) ?? .init()
  }
}

/// The `notifications` object inside `settings.json`. Owns the C6-specific
/// state the coordinator and CLI both mutate: muting preferences, the
/// permission-status cache, the "never prompt" flag, and the 24h cool-down
/// timestamp after a `.notNow` decision.
public nonisolated struct NotificationsSettings: Equatable, Codable, Sendable {
  public var mute: MuteSettings
  public var authStatus: AuthorizationStatusCache
  public var neverPrompt: Bool
  /// Timestamp after which the coordinator may present the pre-prompt again
  /// after a `.notNow` decision. `nil` means no cool-down active.
  public var notNowUntil: Date?

  public init(
    mute: MuteSettings = .defaults,
    authStatus: AuthorizationStatusCache = .notDetermined,
    neverPrompt: Bool = false,
    notNowUntil: Date? = nil
  ) {
    self.mute = mute
    self.authStatus = authStatus
    self.neverPrompt = neverPrompt
    self.notNowUntil = notNowUntil
  }
}

/// Mirror of `AuthorizationStatus` (from `OSNotifier.swift`) lifted into
/// `TouchCodeCore`-adjacent persisted shape. Kept as a separate type because
/// `AuthorizationStatus` lives in the app target alongside `UserNotifications`;
/// we do not import `UserNotifications` into the pure-Swift settings layer.
public nonisolated enum AuthorizationStatusCache: String, Equatable, Codable, Sendable {
  case notDetermined
  case authorized
  case denied
  case provisional
}

/// `@MainActor` wrapper around `~/.config/touch-code/settings.json`. Mirrors
/// `CatalogStore`'s pattern: `AtomicFileStore` writes, 500ms debounced trailing
/// saves, synchronous flush on `applicationWillTerminate`. No row-cap (unlike
/// `InboxStore`); settings is a flat preferences object.
@MainActor
final class NotificationSettingsStore {
  private(set) var settings: TouchCodeSettings = .default

  private let fileURL: URL
  private let clock: any Clock<Duration>
  private let debounce: Duration
  private let logger = Logger(subsystem: "com.touch-code.notifications", category: "settings")
  private var pendingSaveTask: Task<Void, Never>?

  init(
    fileURL: URL = ConfigPaths.configDirectory().appendingPathComponent("settings.json", isDirectory: false),
    clock: any Clock<Duration> = ContinuousClock(),
    debounce: Duration = .milliseconds(500)
  ) {
    self.fileURL = fileURL
    self.clock = clock
    self.debounce = debounce
  }

  deinit { pendingSaveTask?.cancel() }

  @discardableResult
  func load() throws -> TouchCodeSettings {
    do {
      if let existing = try AtomicFileStore.read(TouchCodeSettings.self, at: fileURL) {
        settings = existing
      } else {
        settings = .default
      }
    } catch TouchCodeSettings.DecodingIssue.unsupportedVersion(let v) {
      logger.error("Unsupported settings.json version \(v); backing up and starting defaults.")
      backupBrokenFile()
      settings = .default
    } catch {
      logger.error("Failed to decode settings.json: \(String(describing: error)); backing up and starting defaults.")
      backupBrokenFile()
      settings = .default
    }
    return settings
  }

  /// Mutate the in-memory settings through a closure and schedule a debounced save.
  func mutate(_ change: (inout TouchCodeSettings) -> Void) {
    change(&settings)
    scheduleSave()
  }

  func saveNow() throws {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    try AtomicFileStore.write(settings, to: fileURL)
  }

  private func scheduleSave() {
    pendingSaveTask?.cancel()
    pendingSaveTask = Task { [clock, debounce, weak self] in
      do {
        try await clock.sleep(for: debounce, tolerance: nil)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.flushPending()
    }
  }

  private func flushPending() {
    do {
      try AtomicFileStore.write(settings, to: fileURL)
    } catch {
      logger.error("Failed to save settings.json: \(String(describing: error))")
    }
  }

  private func backupBrokenFile() {
    BrokenFileBackup.moveAside(at: fileURL, logger: logger)
  }
}
