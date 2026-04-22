import Foundation
import TouchCodeCore

/// Stateless helper that preserves the Developer pane's hook snapshot on
/// reload failure. Extracted from `DeveloperSettingsView` so the contract —
/// "on error, keep the previous subscriptions and surface an inline error" —
/// can be verified without rendering SwiftUI. Intentionally `nonisolated` —
/// it holds no state and the derivation is pure, so tests can call it from
/// either isolation domain.
nonisolated enum HookReloader {
  /// `(subscriptions, error)` pair returned from a reload attempt.
  /// - On success: new subscriptions, `error == nil`.
  /// - On throw: `previous` re-returned verbatim, `error` contains a
  ///   human-readable summary rendered inline by the view.
  struct Outcome: Equatable {
    var subscriptions: [HookSubscription]
    var error: String?
  }

  static func reload(
    previous: [HookSubscription],
    load: () throws -> HookConfig
  ) -> Outcome {
    do {
      let config = try load()
      return Outcome(subscriptions: config.subscriptions, error: nil)
    } catch {
      return Outcome(subscriptions: previous, error: summary(for: error))
    }
  }

  static func summary(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return String(describing: error)
  }
}
