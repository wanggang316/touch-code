import Foundation
@preconcurrency import UserNotifications

/// Routes user actions on macOS notification banners back into the inbox.
///
/// `OSNotifier` registers two `UNNotificationAction`s on every category:
/// `focus` (default-style) and `dismiss` (destructive). When a user taps
/// either — or taps the notification body itself, which fires
/// `UNNotificationDefaultActionIdentifier` — we route that signal so the
/// in-app inbox stays in lock-step with the OS surface. Without this
/// delegate, "Dismiss" on the OS banner only clears the banner; the
/// corresponding inbox row survives, contradicting the in-app swipe.
///
/// The `handle(actionIdentifier:notificationID:)` method is exposed
/// separately from the framework callback so tests can drive the routing
/// directly without constructing a `UNNotificationResponse` (which has no
/// public initialiser).
@MainActor
final class UserNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  /// Tap on body or `focus` action — the user wants to attend to this
  /// notification's pane. Receives the notification's UUID; the wirer
  /// (`C6AppBootstrap`) closes over the inbox to mark read and over the
  /// deeplink router to focus the pane.
  let onFocus: @MainActor (UUID) -> Void
  /// Tap on the `dismiss` action — peer of the in-app swipe.
  let onDismiss: @MainActor (UUID) -> Void

  init(
    onFocus: @escaping @MainActor (UUID) -> Void,
    onDismiss: @escaping @MainActor (UUID) -> Void
  ) {
    self.onFocus = onFocus
    self.onDismiss = onDismiss
  }

  /// Dispatch a tapped action by identifier strings. Public surface for
  /// unit tests that cannot synthesise a `UNNotificationResponse`.
  func handle(actionIdentifier: String, notificationID: String) {
    guard let id = UUID(uuidString: notificationID) else { return }
    switch actionIdentifier {
    case "dismiss":
      onDismiss(id)
    case "focus", UNNotificationDefaultActionIdentifier:
      onFocus(id)
    default:
      break
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionIdentifier = response.actionIdentifier
    let notificationID = response.notification.request.identifier
    // Ack synchronously: UN only requires timely completion, not that
    // the @MainActor work below finishes first. Keeps the closure off
    // the main-actor hop and clear of Swift-6 sendability traps.
    completionHandler()
    Task { @MainActor [weak self] in
      self?.handle(actionIdentifier: actionIdentifier, notificationID: notificationID)
    }
  }

  /// Foreground presentation: keep the system banner + sound for live
  /// notifications fired while the app is active.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
