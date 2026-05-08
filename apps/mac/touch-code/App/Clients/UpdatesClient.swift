import ComposableArchitecture
import Foundation
import Sparkle
import os.log

/// TCA seam for the "Check for Updates" action. Wraps Sparkle's
/// `SPUStandardUpdaterController` so feature code can call `checkNow`
/// without importing Sparkle. The controller lives in
/// `UpdatesEnvironment` so the Settings → Updates pane shares the same
/// instance instead of standing up a parallel one.
nonisolated struct UpdatesClient: Sendable {
  var checkNow: @MainActor @Sendable () -> Void
}

extension UpdatesClient: DependencyKey {
  private static let logger = Logger(subsystem: "com.touch-code.ui", category: "updates")

  static let liveValue = UpdatesClient(
    checkNow: {
      logger.info("checkForUpdates triggered")
      UpdatesEnvironment.updater.checkForUpdates()
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
