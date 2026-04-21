import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency bridge over `HookConfigStore`. The Hooks pane's
/// `.onHooksAppear` effect loads hooks.json through this client so
/// the load path is injectable in tests and does not block the main thread.
nonisolated struct HookConfigClient: Sendable {
  /// Load current hooks.json. Returns `.empty` if the file is missing
  /// (HookConfigStore already guarantees this). Throws the underlying
  /// AtomicFileStore error on corruption (HookConfigStore logs and backs
  /// up the broken file before returning `.empty` at load time).
  var load: @MainActor @Sendable () async throws -> HookConfig

  /// Create an empty hooks.json at the default path when it does not exist.
  /// No-op when the file is already present. Used before Reveal so Finder
  /// always opens something (spec Acceptance Criteria). Throws the underlying
  /// AtomicFileStore error on write failure.
  var ensureExists: @MainActor @Sendable () async throws -> Void
}

// MARK: - Live bridge

extension HookConfigClient {
  @MainActor
  static func live(store: HookConfigStore) -> HookConfigClient {
    HookConfigClient(
      load: {
        try store.load()
      },
      ensureExists: {
        let url = HookConfig.defaultURL()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try store.save(.empty)
      }
    )
  }
}

// MARK: - DependencyKey

extension HookConfigClient: DependencyKey {
  static let liveValue: HookConfigClient = HookConfigClient(
    load: {
      fatalError("HookConfigClient.liveValue not configured; wire via .withDependencies at app startup")
    },
    ensureExists: {
      fatalError("HookConfigClient.liveValue not configured")
    }
  )

  static let testValue: HookConfigClient = HookConfigClient(
    load: unimplemented("HookConfigClient.load"),
    ensureExists: unimplemented("HookConfigClient.ensureExists")
  )
}

extension DependencyValues {
  var hookConfigClient: HookConfigClient {
    get { self[HookConfigClient.self] }
    set { self[HookConfigClient.self] = newValue }
  }
}
