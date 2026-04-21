import Foundation
import os
import TouchCodeCore

/// Errors surfaced during config load / save. Catalogued in the C3 design
/// doc §Error handling model.
public enum HookConfigError: Error, Equatable, Sendable {
  /// The subscription's regex pattern failed to compile.
  case invalidRegex(id: UUID, pattern: String, message: String)
  /// The subscription's `env` used a reserved `TOUCH_CODE_*` key.
  case reservedEnv(id: UUID, key: String)
  /// The subscription's `command` starts with the reserved
  /// `__touch-code/internal:` namespace but was loaded via the user-path
  /// `load()` (not through `upsertInternal(_:)`).
  case reservedPrefix(id: UUID, command: String)
  /// `upsertInternal(_:)` was called with a subscription whose `command`
  /// does **not** start with the reserved internal prefix.
  case reservedPrefixRequired(id: UUID, command: String)
}

@MainActor
public final class HookConfigStore {
  public static let defaultDebounceSeconds: TimeInterval = 0.5

  private let fileURL: URL
  private let debounceSeconds: TimeInterval
  private var debounceTask: Task<Void, Never>?
  /// Latest payload handed to `scheduleSave` but not yet flushed. `flush()`
  /// drains this on shutdown; `scheduleSave` overwrites it atomically.
  private var pendingConfig: HookConfig?
  private let logger = Logger(subsystem: "com.touch-code.hooks", category: "config")

  public init(
    fileURL: URL = HookConfig.defaultURL(),
    debounceSeconds: TimeInterval = HookConfigStore.defaultDebounceSeconds
  ) {
    self.fileURL = fileURL
    self.debounceSeconds = debounceSeconds
  }

  /// Load the user-authored config from disk. Rejects subscriptions that
  /// claim the reserved internal namespace, have reserved env keys, or
  /// carry an invalid regex; valid subscriptions still load even if some
  /// siblings are rejected. On decode failure, the file is renamed to a
  /// `hooks.json.broken-<ISO8601>` backup and `.empty` is returned.
  public func load() throws -> HookConfig {
    let raw: HookConfig
    do {
      let decoded = try AtomicFileStore.read(HookConfig.self, at: fileURL)
      raw = decoded ?? .empty
    } catch {
      try backupBrokenFile(reason: String(describing: error))
      logger.error("hooks.json decode failed; backed up and returning empty config: \(String(describing: error), privacy: .public)")
      return .empty
    }
    return try validate(raw, allowInternalNamespace: false)
  }

  /// Synchronous flush. Used on app-quit and in tests.
  public func save(_ config: HookConfig) throws {
    try AtomicFileStore.write(config, to: fileURL)
  }

  /// Debounced save. A second call within `debounceSeconds` cancels the
  /// pending write and restarts the timer with the latest value.
  public func scheduleSave(_ config: HookConfig) {
    debounceTask?.cancel()
    pendingConfig = config
    debounceTask = Task { [fileURL, debounceSeconds, logger] in
      let nanos = UInt64(debounceSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      guard !Task.isCancelled else { return }
      do {
        try AtomicFileStore.write(config, to: fileURL)
        self.pendingConfig = nil
      } catch {
        logger.error("debounced save failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  /// Cancel any pending debounced save and synchronously flush the last
  /// `scheduleSave` payload to disk. Call on app-quit so ~500 ms of
  /// just-scheduled edits don't vanish when the process goes away before
  /// the debounce timer fires. Idempotent — a no-op when nothing is
  /// pending. Throws the underlying `AtomicFileStore` error on write
  /// failure so the shutdown path can log / surface it.
  public func flush() throws {
    debounceTask?.cancel()
    debounceTask = nil
    guard let pending = pendingConfig else { return }
    pendingConfig = nil
    try AtomicFileStore.write(pending, to: fileURL)
  }

  // MARK: - Internal-namespace API (exec-plan 0003 M2 for C6 consumption)

  /// Atomically insert-or-replace first-party subscriptions in the reserved
  /// internal namespace. Every supplied subscription's `command` must start
  /// with `touchCodeInternalPrefix`; otherwise throws
  /// `HookConfigError.reservedPrefixRequired`. Existing user subscriptions
  /// outside the namespace are untouched.
  public func upsertInternal(_ subscriptions: [HookSubscription]) throws {
    for sub in subscriptions {
      guard sub.command.hasPrefix(touchCodeInternalPrefix) else {
        throw HookConfigError.reservedPrefixRequired(id: sub.id, command: sub.command)
      }
    }
    var config = (try? loadRaw()) ?? .empty
    let incomingIDs = Set(subscriptions.map(\.id))
    var merged = config.subscriptions.filter { !incomingIDs.contains($0.id) }
    merged.append(contentsOf: subscriptions)
    config.subscriptions = merged
    try save(config)
  }

  /// Remove every subscription whose `command` starts with `prefix`. The
  /// prefix must itself start with the reserved internal namespace, or the
  /// call throws `reservedPrefixRequired`.
  public func removeInternal(idsPrefixed prefix: String) throws {
    guard prefix.hasPrefix(touchCodeInternalPrefix) else {
      throw HookConfigError.reservedPrefixRequired(id: UUID(), command: prefix)
    }
    var config = (try? loadRaw()) ?? .empty
    config.subscriptions.removeAll { $0.command.hasPrefix(prefix) }
    try save(config)
  }

  // MARK: - Helpers

  /// Raw load: decodes, but accepts internal-namespace subscriptions. Used
  /// by the internal-namespace APIs when they need to round-trip through
  /// disk without re-rejecting their own entries.
  private func loadRaw() throws -> HookConfig {
    let decoded = try AtomicFileStore.read(HookConfig.self, at: fileURL)
    return try validate(decoded ?? .empty, allowInternalNamespace: true)
  }

  private func validate(_ config: HookConfig, allowInternalNamespace: Bool) throws -> HookConfig {
    var kept: [HookSubscription] = []
    for sub in config.subscriptions {
      do {
        try validate(sub, allowInternalNamespace: allowInternalNamespace)
        kept.append(sub)
      } catch {
        logger.warning("dropping subscription \(sub.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
    var copy = config
    copy.subscriptions = kept
    return copy
  }

  private func validate(_ sub: HookSubscription, allowInternalNamespace: Bool) throws {
    if sub.command.hasPrefix(touchCodeInternalPrefix), !allowInternalNamespace {
      throw HookConfigError.reservedPrefix(id: sub.id, command: sub.command)
    }
    for key in sub.env.keys where key.hasPrefix("TOUCH_CODE_") {
      throw HookConfigError.reservedEnv(id: sub.id, key: key)
    }
    if let pattern = sub.matchPattern, !pattern.isEmpty {
      do {
        _ = try NSRegularExpression(pattern: pattern)
      } catch {
        throw HookConfigError.invalidRegex(id: sub.id, pattern: pattern, message: error.localizedDescription)
      }
    }
  }

  /// Back up the on-disk file before the caller overwrites it with a
  /// default/empty config. Uses copy-then-delete so that a failure mid-way
  /// leaves either the original file intact (copy failed) or both the
  /// backup and original present (delete failed) — never the zero-backup
  /// state that `moveItem` would leave on a partial failure.
  private func backupBrokenFile(reason: String) throws {
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let backup = fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).broken-\(stamp)")
    do {
      try FileManager.default.copyItem(at: fileURL, to: backup)
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      logger.error("backup of broken hooks.json failed: \(String(describing: error), privacy: .public)")
    }
  }
}
