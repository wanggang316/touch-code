import Foundation
import TouchCodeCore

@testable import touch_code

// swiftlint:disable async_without_await
//
// The conforming members below are `async` because the production
// `OSNotifier` protocol requires it; the mock has no real async work to do.

/// Test double for `OSNotifier`. Matches the CURRENT `post(_:)` signature;
/// M2.T2 introduces a `playSound:` parameter and updates this mock together
/// with the protocol change.
@MainActor
final class MockOSNotifier: OSNotifier {
  var status: AuthorizationStatus = .authorized
  private(set) var posts: [InboxEntry] = []

  func currentAuthorizationStatus() async -> AuthorizationStatus { status }

  func requestAuthorization() async -> AuthorizationStatus { status }

  func post(_ entry: InboxEntry) async {
    posts.append(entry)
  }
}
// swiftlint:enable async_without_await
