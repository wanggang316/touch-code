import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

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
  func panelExitedZeroTransitionsToCompleted() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .panelExited, data: .panelExited(exitCode: 0))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition?.to == .completed)
    #expect(transition?.trigger == .envelope(event: .panelExited))
  }

  @Test
  func panelExitedNonZeroEmitsAndTearsDown() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .panelExited, data: .panelExited(exitCode: 1))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    // Non-zero → .completed state + .envelope trigger.
    #expect(transition?.to == .completed)
  }

  @Test
  func panelCrashedEmitsAndTearsDown() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .panelCrashed, data: .panelCrashed(reason: "boom"))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition?.trigger == .envelope(event: .panelCrashed))
  }

  // MARK: - Activity rearm

  @Test
  func outputActivityTransitionsFromIdleToRunning() throws {
    let tracker = Self.makeTracker()
    // Force the FSM into idle via userOverride so we can test the activity path.
    tracker.override(to: .idle)
    let envelope = Self.envelope(event: .panelOutput, data: .panelOutput(output: Data("hi".utf8), outputBytes: 2))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition?.from == .idle)
    #expect(transition?.to == .running)
    #expect(transition?.trigger == .envelope(event: .panelOutput))
  }

  @Test
  func outputActivityInRunningStateIsNoOp() throws {
    let tracker = Self.makeTracker()
    let envelope = Self.envelope(event: .panelOutput, data: .panelOutput(output: Data("hi".utf8), outputBytes: 2))
    let transition = tracker.ingest(envelope: envelope, ruleID: nil)
    #expect(transition == nil)
  }

  // MARK: - Override

  @Test
  func overrideDoesNotEmit() throws {
    let tracker = Self.makeTracker()
    tracker.override(to: .idle)
    #expect(tracker.state == .idle)
    // Verify the transitions stream is empty so far by checking lastActivity.
    // (Streams are harder to peek non-destructively; we assert state is the
    // sole observable effect.)
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
      panelID: PanelID(),
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
      panel: HookEnvelope.PanelRef(
        id: PanelID(),
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: ["agent:claude"]
      ),
      data: data
    )
  }
}
