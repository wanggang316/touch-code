import ComposableArchitecture
import Foundation
import os.log

/// TCA seam for the "Check for Updates" action. Sparkle isn't currently
/// integrated (the `SparkleUpdates` / `UpdatesFeature` plan lives in
/// `docs/architecture.md` §Technology Choices); the live closure logs at
/// `.info` so keybind-triggered invocations are diagnosable without
/// surfacing a user-facing toast before the updater exists.
///
/// Once Sparkle lands, `checkNow` forwards to the updater's
/// `checkForUpdates(_:)` on the main thread — the closure signature is
/// already correct.
nonisolated struct UpdatesClient: Sendable {
  var checkNow: @MainActor @Sendable () -> Void
}

extension UpdatesClient: DependencyKey {
  private static let logger = Logger(subsystem: "com.touch-code.ui", category: "updates")

  static let liveValue = UpdatesClient(
    checkNow: {
      logger.info("checkForUpdates requested but Sparkle not wired")
    }
  )

  static let testValue = UpdatesClient(
    checkNow: unimplemented("UpdatesClient.checkNow")
  )
}

extension DependencyValues {
  var updatesClient: UpdatesClient {
    get { self[UpdatesClient.self] }
    set { self[UpdatesClient.self] = newValue }
  }
}
