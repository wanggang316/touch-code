import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct AgentStateTrackerTests {
  // MARK: - Rule-driven transitions

  @Test
  func runningToBlockedOnInputEmits() throws {
    let tracker = Self.makeTracker()
    let transition = tracker.applyRuleTransition(to: .blockedOnInput, ruleID: "rule.blocked")
    #expect(transition != nil)
    #expect(tracker.state == .blockedOnInput)
    #expect(transition?.from == .running)
    #expect(transition?.to == .blockedOnInput)
    #expect(transition?.trigger == .rule(id: "rule.blocked"))
  }

  @Test
  func runningToCompletedEmits() throws {
    let tracker = Self.makeTracker()
    let transition = tracker.applyRuleTransition(to: .completed, ruleID: "rule.done")
    #expect(transition != nil)
    #expect(tracker.state == .completed)
  }

  @Test
  func selfTransitionDoesNotEmit() throws {
    let tracker = Self.makeTracker()
    _ = tracker.applyRuleTransition(to: .completed, ruleID: "rule.done")
    // Apply the same target state again — should NOT emit.
    let second = tracker.applyRuleTransition(to: .completed, ruleID: "rule.done")
    #expect(second == nil)
  }

  // MARK: - Envelope-driven transitions

  @Test
  func paneExitedZeroTransitionsToCompleted() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .paneExited, data: .paneExited(exitCode: 0))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition?.to == .completed)
    #expect(transition?.trigger == .envelope(event: .paneExited))
  }

  @Test
  func paneExitedNonZeroEmitsAndTearsDown() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .paneExited, data: .paneExited(exitCode: 1))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    // Non-zero → .completed state + .envelope trigger.
    #expect(transition?.to == .completed)
  }

  @Test
  func paneCrashedEmitsAndTearsDown() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .paneCrashed, data: .paneCrashed(reason: "boom"))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition?.trigger == .envelope(event: .paneCrashed))
  }

  // MARK: - Activity rearm

  @Test
  func outputActivityTransitionsFromIdleToRunning() throws {
    let tracker = Self.makeTracker()
    // Force the FSM into idle via userOverride so we can test the activity path.
    tracker.override(to: .idle)
    let envelope = Self.envelope(event: .paneOutput, data: .paneOutput(output: Data("hi".utf8), outputBytes: 2))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition?.from == .idle)
    #expect(transition?.to == .running)
    #expect(transition?.trigger == .envelope(event: .paneOutput))
  }

  @Test
  func outputActivityInRunningStateIsNoOp() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .paneOutput, data: .paneOutput(output: Data("hi".utf8), outputBytes: 2))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition == nil)
  }

  // MARK: - Override

  @Test
  func overrideDoesNotEmit() async throws {
    let tracker = Self.makeTracker()
    var iterator = tracker.transitions.makeAsyncIterator()
    tracker.override(to: .idle)
    #expect(tracker.state == .idle)
    // Assert no transition reaches the stream within a short window. Using
    // withTaskGroup + withTimeout would be heavier; a microsleep is enough
    // because the stream has no pending yields.
    let racer = Task {
      await iterator.next()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    racer.cancel()
    let result = await racer.value
    #expect(result == nil)
  }

  // MARK: - User-interaction suppression (v2 D4)

  /// User-typing within the suppression window must drop a rule-driven
  /// completion transition off the stream — the user is already
  /// attending to that pane, a banner would be redundant.
  @Test
  func userInputSuppressesCompletionWithinWindow() async throws {
    let tracker = Self.makeTracker()
    var iterator = tracker.transitions.makeAsyncIterator()

    tracker.recordUserInput()
    let returned = tracker.applyRuleTransition(to: .completed, ruleID: "rule.done")
    #expect(returned != nil)  // state moved
    #expect(tracker.state == .completed)

    let racer = Task { await iterator.next() }
    try await Task.sleep(nanoseconds: 50_000_000)
    racer.cancel()
    #expect(await racer.value == nil)
  }

  /// `.blockedOnInput` is the one signal a typing user actually wants —
  /// the agent is asking for them. Suppression must NOT swallow it.
  @Test
  func userInputDoesNotSuppressBlockedOnInput() async throws {
    let tracker = Self.makeTracker()
    var iterator = tracker.transitions.makeAsyncIterator()

    tracker.recordUserInput()
    _ = tracker.applyRuleTransition(to: .blockedOnInput, ruleID: "rule.ask")

    let next = await iterator.next()
    #expect(next?.to == .blockedOnInput)
  }

  /// After the 3-second window expires, completions notify normally
  /// again. The test stamps a synthetic user-input timestamp into the
  /// past so it does not depend on `Task.sleep`.
  @Test
  func userInputAfterWindowAllowsCompletion() async throws {
    let tracker = Self.makeTracker()
    var iterator = tracker.transitions.makeAsyncIterator()

    tracker.recordUserInput(at: Date().addingTimeInterval(-5))
    _ = tracker.applyRuleTransition(to: .completed, ruleID: "rule.done")

    let next = await iterator.next()
    #expect(next?.to == .completed)
  }

  // MARK: - Idle timer (sleep/wake safe — R1 coverage)

  @Test
  func idleTimerFiresAfterThresholdWithoutActivity() async throws {
    let tracker = AgentStateTracker(
      paneID: PaneID(),
      idleThreshold: 0.05,
      clock: ContinuousClock(),
      now: Date()
    )
    var iterator = tracker.transitions.makeAsyncIterator()
    // No activity for > threshold — expect one .idle transition.
    let transition = await iterator.next()
    #expect(transition?.to == .idle)
    if case .idleTimer(let seconds) = transition?.trigger {
      #expect(seconds == 0.05)
    } else {
      Issue.record("Expected .idleTimer; got \(String(describing: transition?.trigger))")
    }
  }

  @Test
  func idleTimerRearmsIfActivityOccurredDuringSleep() async throws {
    // R1 coverage: activity during the idle sleep must rearm the timer,
    // so the resulting idle transition fires AFTER (activity + threshold)
    // rather than at the original threshold. This avoids a single-
    // iterator-cancel race by measuring wall-clock elapsed time from
    // tracker init to the emitted idle.
    let threshold: TimeInterval = 0.2
    let activityDelay: TimeInterval = 0.1
    let tracker = AgentStateTracker(
      paneID: PaneID(),
      idleThreshold: threshold,
      clock: ContinuousClock(),
      now: Date()
    )
    let startedAt = Date()

    try await Task.sleep(nanoseconds: UInt64(activityDelay * 1_000_000_000))
    let envelope = Self.envelope(
      event: .paneOutput,
      data: .paneOutput(output: Data("x".utf8), outputBytes: 1)
    )
    _ = tracker.ingest(envelope: envelope, ruleID: nil)

    // Consume the first transition — must be the rearmed idle.
    var iterator = tracker.transitions.makeAsyncIterator()
    let transition = await iterator.next()
    let firedAt = Date()

    #expect(transition?.to == .idle)
    let elapsed = firedAt.timeIntervalSince(startedAt)
    // Without the rearm, elapsed would be ≈ threshold (0.2s). With the
    // rearm, elapsed should be ≈ activityDelay + threshold (0.3s). Allow
    // a 30ms jitter band below the rearm target.
    #expect(elapsed >= activityDelay + threshold - 0.03)
  }

  // MARK: - Teardown

  @Test
  func teardownFinishesTransitionsStream() async throws {
    let tracker = Self.makeTracker()
    var iterator = tracker.transitions.makeAsyncIterator()
    _ = tracker.applyRuleTransition(to: .completed, ruleID: "rule.done")
    let first = await iterator.next()
    #expect(first?.to == .completed)
    tracker.teardown()
    let next = await iterator.next()
    #expect(next == nil)
  }

  // MARK: - Helpers

  private static func makeTracker(idleThreshold: TimeInterval = 120) -> AgentStateTracker {
    AgentStateTracker(
      paneID: PaneID(),
      idleThreshold: idleThreshold,
      clock: ContinuousClock(),
      now: Date()
    )
  }

  private static func envelope(event: HookEvent, data: HookEventData) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: event,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      pane: HookEnvelope.PaneRef(
        id: PaneID(),
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: ["agent:claude"]
      ),
      data: data
    )
  }
}
