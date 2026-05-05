import ComposableArchitecture
import Foundation
import Sparkle
import os.log

/// TCA seam for the "Check for Updates" action. Wraps Sparkle's
/// `SPUStandardUpdaterController` so feature code can call `checkNow`
/// without importing Sparkle. The controller is retained for the
/// lifetime of the process via a static singleton — Sparkle requires
/// it to keep the periodic background check timer alive.
nonisolated struct UpdatesClient: Sendable {
  var checkNow: @MainActor @Sendable () -> Void
}

extension UpdatesClient: DependencyKey {
  private static let logger = Logger(subsystem: "com.touch-code.ui", category: "updates")

  /// Lazily-initialized on first access; @MainActor-isolated because
  /// `SPUStandardUpdaterController.init(startingUpdater:...)` schedules
  /// timers on the main runloop and Sparkle's API is documented as
  /// main-thread-only.
  @MainActor
  private static let controller: SPUStandardUpdaterController = {
    SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }()

  static let liveValue = UpdatesClient(
    checkNow: {
      logger.info("checkForUpdates triggered")
      controller.updater.checkForUpdates()
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
