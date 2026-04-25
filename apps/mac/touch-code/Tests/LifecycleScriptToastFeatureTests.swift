import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// TestStore coverage for `LifecycleScriptToastFeature`. The auto-dismiss
/// path uses `TestClock` so the 5s timer is deterministic.
@MainActor
struct LifecycleScriptToastFeatureTests {
  private func makeState() -> LifecycleScriptToastFeature.State {
    LifecycleScriptToastFeature.State(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      phase: .setup,
      worktreeName: "feature/foo"
    )
  }

  @Test
  func successSchedulesAutoDismissAfterFiveSeconds() async {
    let clock = TestClock()
    let store = TestStore(initialState: makeState()) {
      LifecycleScriptToastFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.finished(.success(stdout: "ok"))) {
      $0.output = "ok"
      $0.exitState = .succeeded
    }
    await clock.advance(by: .seconds(5))
    await store.receive(\.autoDismissAfterDelay)
    await store.receive(\.dismiss)
  }

  @Test
  func failureDoesNotAutoDismiss() async {
    let clock = TestClock()
    let store = TestStore(initialState: makeState()) {
      LifecycleScriptToastFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.finished(.failure(exitCode: 7, stdout: "boom"))) {
      $0.output = "boom"
      $0.exitState = .failed(exitCode: 7)
    }
    // Advance well past 5s — no `.autoDismissAfterDelay` should arrive.
    await clock.advance(by: .seconds(60))
    // Manual dismiss flips through the .dismiss case.
    await store.send(.dismissTapped)
  }

  @Test
  func skippedResultDispatchesDismiss() async {
    let clock = TestClock()
    let store = TestStore(initialState: makeState()) {
      LifecycleScriptToastFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.finished(.skipped))
    await store.receive(\.dismiss)
  }

  @Test
  func appendOutputAccumulatesBuffer() async {
    let clock = TestClock()
    let store = TestStore(initialState: makeState()) {
      LifecycleScriptToastFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.appendOutput("part 1\n")) {
      $0.output = "part 1\n"
    }
    await store.send(.appendOutput("part 2")) {
      $0.output = "part 1\npart 2"
    }
  }

  @Test
  func cancelTappedDispatchesDismiss() async {
    let clock = TestClock()
    let store = TestStore(initialState: makeState()) {
      LifecycleScriptToastFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    await store.send(.cancelTapped)
    await store.receive(\.dismiss)
  }
}
