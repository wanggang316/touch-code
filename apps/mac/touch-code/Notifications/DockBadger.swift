import AppKit
import Foundation

/// Adapter protocol over `NSApp.dockTile.badgeLabel` so the coordinator can be
/// tested without running a bundled foreground app.
///
/// Count semantics (design DEC-13): the count is the number of unread,
/// non-dismissed `AgentNotification`s in the inbox regardless of OS-banner
/// mute status. The badge mirrors the inbox's "Unread" filter exactly.
@MainActor
protocol DockBadger: AnyObject {
  func setUnreadCount(_ n: Int)
}

/// Production adapter.
///
/// Rendering: `""` / no label when zero; decimal count when ≤ 99; `"99+"`
/// beyond. Must only be constructed from the app shell; unit tests use
/// `MockDockBadger` to avoid touching `NSApp` inside an unbundled test host.
@MainActor
final class AppKitDockBadger: DockBadger {
  init() {}

  func setUnreadCount(_ n: Int) {
    let tile = NSApp.dockTile
    tile.badgeLabel = Self.render(n)
  }

  /// Pure-function formatter exposed for unit tests; equivalent to the string
  /// set on `NSApp.dockTile.badgeLabel`. `nil` means "clear the badge".
  nonisolated static func render(_ n: Int) -> String? {
    if n <= 0 { return nil }
    if n > 99 { return "99+" }
    return String(n)
  }
}
