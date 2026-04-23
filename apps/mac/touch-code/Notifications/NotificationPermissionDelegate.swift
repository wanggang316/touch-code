import Foundation

/// Result of the first-run permission sheet per DEC-4.
///
/// - `continue`: invoke `UNUserNotificationCenter.requestAuthorization`.
/// - `notNow`: set a 24h cool-down; re-prompt next agent-Pane creation after expiry.
/// - `never`: permanently suppress the pre-prompt; inbox + Dock badge continue working.
enum PermissionDecision: String, Sendable, Codable {
  case `continue`
  case notNow
  case never
}

/// Supplied by M5's UI layer. M4a ships the no-op fallback `NullPermissionDelegate`
/// so development builds can exercise the OS surface without presenting a sheet
/// (Apple's system-level prompt suffices for engineering work). M5 swaps in a
/// SwiftUI-backed delegate that presents the touch-code-branded pre-prompt with
/// Continue / Not now / Never buttons.
@MainActor
protocol NotificationPermissionDelegate: AnyObject {
  func presentPrompt() async -> PermissionDecision
}

/// No-op pre-prompt: always returns `.continue` so the coordinator proceeds
/// directly to `UNUserNotificationCenter.requestAuthorization`. Used in M4a
/// and dev builds; replaced by `NotificationPermissionViewModel` in M5.
@MainActor
final class NullPermissionDelegate: NotificationPermissionDelegate {
  init() {}
  func presentPrompt() async -> PermissionDecision {
    // Yield once so the call behaves asynchronously — matches the real sheet's
    // await semantics and satisfies "async must await" lint in release builds.
    await Task.yield()
    return .continue
  }
}
