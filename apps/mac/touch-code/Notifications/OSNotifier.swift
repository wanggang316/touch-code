import Foundation
import TouchCodeCore
@preconcurrency import UserNotifications

/// Cached + query-fresh macOS notification permission status. The app shell
/// reads the cache once on launch per DEC-4 permission flow; the coordinator
/// re-queries on `applicationDidBecomeActive` to catch permission changes
/// made in System Settings while the app was running (R2 in the exec plan).
enum AuthorizationStatus: String, Sendable, Codable {
  case notDetermined
  case authorized
  case denied
  case provisional
}

/// Adapter protocol over `UNUserNotificationCenter` so the coordinator can be
/// tested without a live notification daemon. The `post` method is a no-op when
/// the status is `.denied` — the inbox + Dock badge continue to work (DEC-5).
@MainActor
protocol OSNotifier: AnyObject {
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ notification: AgentNotification) async
}

/// Production adapter over `UNUserNotificationCenter.current()`.
///
/// Per design §Surfaces: `threadIdentifier = panelID` groups per-Panel,
/// `categoryIdentifier = kind` drives the per-kind action buttons
/// (Focus Panel / Dismiss), and `userInfo["deeplink"]` routes a click back to
/// `DeeplinkRouter` as `touch-code://panel/<id>/focus`.
@MainActor
final class UserNotificationsOSNotifier: OSNotifier {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    registerCategories()
  }

  func currentAuthorizationStatus() async -> AuthorizationStatus {
    let settings = await center.notificationSettings()
    return Self.map(settings.authorizationStatus)
  }

  func requestAuthorization() async -> AuthorizationStatus {
    do {
      _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      // Authorization request failure falls through to the status refetch
      // below — the refetch is the source of truth for the final state.
    }
    return await currentAuthorizationStatus()
  }

  func post(_ notification: AgentNotification) async {
    let status = await currentAuthorizationStatus()
    guard status == .authorized || status == .provisional else { return }

    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.threadIdentifier = notification.panelID.raw.uuidString
    content.categoryIdentifier = notification.kind.rawValue
    content.userInfo = ["deeplink": "touch-code://panel/\(notification.panelID.raw.uuidString)/focus"]
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: notification.id.uuidString,
      content: content,
      trigger: nil
    )
    try? await center.add(request)
  }

  // MARK: - Category registration

  private func registerCategories() {
    let focus = UNNotificationAction(
      identifier: "focus",
      title: "Focus Panel",
      options: [.foreground]
    )
    let dismiss = UNNotificationAction(
      identifier: "dismiss",
      title: "Dismiss",
      options: []
    )
    let categories: Set<UNNotificationCategory> = Set(
      AgentNotification.Kind.allCases.map { kind in
        UNNotificationCategory(
          identifier: kind.rawValue,
          actions: [focus, dismiss],
          intentIdentifiers: [],
          options: []
        )
      }
    )
    center.setNotificationCategories(categories)
  }

  private static func map(_ status: UNAuthorizationStatus) -> AuthorizationStatus {
    switch status {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .authorized, .ephemeral: return .authorized
    case .provisional: return .provisional
    @unknown default: return .denied
    }
  }
}
