import Foundation

/// Window / app-level intent decoded from a libghostty action. The Runtime
/// emits `TerminalEvent.windowActionRequested(request)`;
/// `WindowActionRouterFeature` dispatches to `WindowService`, `UpdatesClient`,
/// `AppLifecycleClient`, or `EditorClient` as appropriate.
///
/// `from:` carries the source panel's ID for intents that need to resolve
/// back to an `NSWindow`. The receiving router performs the mapping —
/// Runtime does not touch NSWindow.
public nonisolated enum WindowActionRequest: Sendable, Equatable {
  case new(from: PanelID)
  case close(from: PanelID)
  case closeAll
  case goto(target: GotoWindowTarget)
  case toggleFullscreen(from: PanelID)
  case toggleMaximize(from: PanelID)
  case toggleTabOverview(from: PanelID)
  case toggleAppVisibility
  case quit
  case checkForUpdates
  case openConfig
}

public nonisolated enum GotoWindowTarget: Sendable, Equatable {
  case previous
  case next
  case last
  case index(Int)
}
