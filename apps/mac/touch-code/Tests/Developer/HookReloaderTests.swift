import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Covers the "preserve previous snapshot on load failure" rule for the
/// Developer pane's Hooks reload. Decoupled from SwiftUI so the invariant can
/// be asserted without rendering the pane.
@Suite("HookReloader")
struct HookReloaderTests {
  private func sampleSubscription(command: String = "run") -> HookSubscription {
    HookSubscription(event: .paneOutput, command: command)
  }

  @Test
  func successReplacesSubscriptionsAndClearsError() {
    let previous = [sampleSubscription(command: "old")]
    let incoming = [sampleSubscription(command: "new-1"), sampleSubscription(command: "new-2")]
    var loaderCalled = false

    let outcome = HookReloader.reload(previous: previous) {
      loaderCalled = true
      return HookConfig(subscriptions: incoming)
    }

    #expect(loaderCalled)
    #expect(outcome.subscriptions.map(\.command) == ["new-1", "new-2"])
    #expect(outcome.error == nil)
  }

  @Test
  func failureKeepsPreviousAndSurfacesError() {
    let previous = [sampleSubscription(command: "A"), sampleSubscription(command: "B")]
    struct ParseError: LocalizedError {
      var errorDescription: String? { "hooks.json: unexpected character at line 3" }
    }

    let outcome = HookReloader.reload(previous: previous) {
      throw ParseError()
    }

    // Contract: snapshot unchanged on failure (spec + master plan point).
    #expect(outcome.subscriptions.map(\.command) == ["A", "B"])
    #expect(outcome.error == "hooks.json: unexpected character at line 3")
  }

  @Test
  func failureFallsBackToDescribingWhenErrorIsNotLocalized() {
    // A plain (non-LocalizedError) error should still surface a non-empty
    // summary rather than crashing or yielding an empty inline bar.
    struct BareError: Error {}

    let outcome = HookReloader.reload(previous: []) { throw BareError() }

    #expect(outcome.subscriptions.isEmpty)
    #expect((outcome.error ?? "").isEmpty == false)
  }
}
