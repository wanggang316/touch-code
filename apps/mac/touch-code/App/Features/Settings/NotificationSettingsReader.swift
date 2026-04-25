import Foundation
import TouchCodeCore

/// Read-only view of the `notifications` sub-tree consumed by C6 (`NotificationCoordinator`,
/// `InboxClient.live`). `SettingsStore` conforms to this protocol in Step 4. Keeping the
/// reader surface read-only lets views observe without accidentally triggering a debounced
/// write path.
///
/// Writers still route through `SettingsStore.mutateNotifications`; the coordinator is
/// additionally passed that closure so it can cache auth status / cool-down timestamps.
@MainActor
protocol NotificationSettingsReader: AnyObject {
  var mute: MuteSettings { get }
  var authStatus: AuthorizationStatusCache { get }
  var neverPrompt: Bool { get }
  var notNowUntil: Date? { get }
  var inAppEnabled: Bool { get }
  var systemEnabled: Bool { get }
  var soundEnabled: Bool { get }
  var dockBadgeEnabled: Bool { get }

  /// Fires once per `mutateNotifications` call. The coordinator's bind
  /// loop subscribes so toggling `inAppEnabled` / `dockBadgeEnabled`
  /// re-evaluates the Dock badge in the same UI tick. Without this, the
  /// badge would lag by one inbox-mutation cycle (D8).
  func notificationsSettingsChanges() -> AsyncStream<Void>
}
