import Sparkle

/// Shared owner of the app-wide `SPUStandardUpdaterController`. Sparkle
/// requires a single retained controller for the lifetime of the process
/// — it owns the periodic background-check timer + XPC services. Both the
/// TCA `UpdatesClient` (menu actions) and the Settings → Updates pane
/// (preference toggles) read through this namespace so they share state
/// instead of fighting over two separate controllers.
@MainActor
enum UpdatesEnvironment {
  static let controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  static var updater: SPUUpdater { controller.updater }
}
