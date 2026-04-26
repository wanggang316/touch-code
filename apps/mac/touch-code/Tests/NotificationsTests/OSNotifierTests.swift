import Foundation
import Testing
@preconcurrency import UserNotifications

@testable import touch_code

/// Tests for `UserNotificationDelegate` — the bridge between OS-banner
/// taps and the in-app inbox. We drive the dispatch directly via
/// `handle(actionIdentifier:notificationID:)` rather than synthesising a
/// `UNNotificationResponse` (which has no public initialiser).
@MainActor
struct OSNotifierTests {
  @Test
  func focusActionInvokesOnFocusClosure() {
    let recorder = ActionRecorder()
    let delegate = recorder.makeDelegate()
    let id = UUID()

    delegate.handle(actionIdentifier: "focus", notificationID: id.uuidString)

    #expect(recorder.focused == [id])
    #expect(recorder.dismissed.isEmpty)
  }

  @Test
  func dismissActionInvokesOnDismissClosure() {
    let recorder = ActionRecorder()
    let delegate = recorder.makeDelegate()
    let id = UUID()

    delegate.handle(actionIdentifier: "dismiss", notificationID: id.uuidString)

    #expect(recorder.dismissed == [id])
    #expect(recorder.focused.isEmpty)
  }

  /// Tap on the body of a banner produces `UNNotificationDefaultActionIdentifier`;
  /// per design v2 D9 / DEC-V we treat that as a focus action.
  @Test
  func defaultActionInvokesOnFocusClosure() {
    let recorder = ActionRecorder()
    let delegate = recorder.makeDelegate()
    let id = UUID()

    delegate.handle(
      actionIdentifier: UNNotificationDefaultActionIdentifier,
      notificationID: id.uuidString
    )

    #expect(recorder.focused == [id])
  }

  @Test
  func unknownActionIdentifierIsIgnored() {
    let recorder = ActionRecorder()
    let delegate = recorder.makeDelegate()

    delegate.handle(actionIdentifier: "garbage", notificationID: UUID().uuidString)

    #expect(recorder.focused.isEmpty)
    #expect(recorder.dismissed.isEmpty)
  }

  /// A malformed identifier (e.g. an `id` from a future schema with a
  /// different format) must not crash; the delegate silently drops it.
  @Test
  func malformedNotificationIdentifierIsIgnored() {
    let recorder = ActionRecorder()
    let delegate = recorder.makeDelegate()

    delegate.handle(actionIdentifier: "focus", notificationID: "not-a-uuid")

    #expect(recorder.focused.isEmpty)
    #expect(recorder.dismissed.isEmpty)
  }

  // MARK: - Recorder

  @MainActor
  final class ActionRecorder {
    private(set) var focused: [UUID] = []
    private(set) var dismissed: [UUID] = []

    func makeDelegate() -> UserNotificationDelegate {
      UserNotificationDelegate(
        onFocus: { [weak self] id in self?.focused.append(id) },
        onDismiss: { [weak self] id in self?.dismissed.append(id) }
      )
    }
  }
}
