import Foundation
import Observation
import TouchCodeCore

/// Per-Panel FSM for one agent-hosted Panel. Exactly one instance exists per
/// tracked Panel, owned by `TrackerRegistry`. Callers drive the FSM by
/// feeding C3 `HookEnvelope`s (plus the optional `ruleID` and rendered
/// template strings that `DetectionRouter` resolves); the tracker emits
/// `AgentStateTransition`s whenever the state changes, and an idle-timer
/// fires a local `.idle` transition after `idleThreshold` seconds of
/// silence (design §FSM Transition Table).
///
/// Notification emission invariants:
/// - Self-transitions (`from == to`) do not emit a transition.
/// - `.panelCrashed` always emits a `.crashed`-class transition (even
///   when already in `.completed`) and then tears down.
/// - `userOverride` may set any state but never emits a transition —
///   it is a correction, not an event.
@MainActor
@Observable
final class AgentStateTracker {
  let panelID: PanelID
  private(set) var state: AgentState = .running
  private(set) var lastActivityAt: Date

  private let idleThreshold: TimeInterval
  private let clock: any Clock<Duration>
  private let (continuation, stream): (AsyncStream<AgentStateTransition>.Continuation, AsyncStream<AgentStateTransition>)
  /// `Task` is `Sendable` and `cancel()` is safe from any context. We
  /// store the handle `nonisolated(unsafe)` so `deinit` can cancel
  /// the pending sleep without hopping to `MainActor`. Mutations stay
  /// on `MainActor` (only `armIdleTimer()` / `teardown()` write).
  private nonisolated(unsafe) var idleTimerTask: Task<Void, Never>?

  init(
    panelID: PanelID,
    idleThreshold: TimeInterval,
    clock: any Clock<Duration> = ContinuousClock(),
    now: Date = Date()
  ) {
    self.panelID = panelID
    self.idleThreshold = idleThreshold
    self.clock = clock
    self.lastActivityAt = now
    let (stream, continuation) = AsyncStream<AgentStateTransition>.makeStream()
    self.stream = stream
    self.continuation = continuation
    armIdleTimer()
  }

  /// Live stream of transitions emitted by the tracker. Consumer: the
  /// `NotificationCoordinator` (M4b) or tests. Cancelling the consumer does
  /// not tear down the tracker.
  var transitions: AsyncStream<AgentStateTransition> { stream }

  deinit {
    // The stream's continuation is nonisolated — finish it unconditionally.
    // The idleTimerTask is MainActor-isolated; finishing the continuation
    // sends the AsyncStream to completion, but we cannot touch
    // `idleTimerTask` from a nonisolated deinit. Callers who care about
    // prompt timer cancellation call `teardown()` explicitly — for pure
    // garbage-collection drop-out, the pending Task.sleep harmlessly
    // observes Task.isCancelled on its next wake (Task holds no strong
    // reference to `self`).
    continuation.finish()
  }

  // MARK: - Ingest

  /// Drive the FSM from a C3-delivered envelope. Returns the emitted
  /// transition, or nil if no state change occurred.
  @discardableResult
  func ingest(
    envelope: HookEnvelope,
    ruleID: String?,
    rendered _: (title: String, body: String)? = nil,
    now: Date = Date()
  ) -> AgentStateTransition? {
    // Activity: any envelope carrying bytes or matched content rearms the
    // idle timer and (if state == .idle) transitions back to .running.
    if Self.isActivity(envelope) {
      lastActivityAt = now
      armIdleTimer()
    }

    switch envelope.event {
    case .panelCrashed:
      let transition = emit(to: .crashedTarget(from: state), trigger: .envelope(event: .panelCrashed), at: now)
      teardown()
      return transition

    case .panelExited:
      if case .panelExited(let code) = envelope.data, code == 0 {
        return transitionIfChanged(to: .completed, trigger: .envelope(event: .panelExited), at: now)
      } else {
        // Non-zero exit is a crash-like signal — emit a crashed transition then teardown.
        let transition = emit(to: .crashedTarget(from: state), trigger: .envelope(event: .panelExited), at: now)
        teardown()
        return transition
      }

    case .panelOutputMatch:
      // Rule lookup + state transition happens in DetectionRouter via
      // applyRuleTransition(to:ruleID:). This branch is a no-op so that
      // a router delegating every envelope still gets the activity timer
      // rearm handled above.
      _ = ruleID
      return nil

    case .panelOutput:
      // Activity already handled above; if we were idle, we've moved to
      // .running via `applyActivityIfNeeded`. No further transition.
      return applyActivityIfNeeded(at: now)

    case .panelInput:
      // User input also counts as activity for the idle timer. Same as output.
      return applyActivityIfNeeded(at: now)

    default:
      return nil
    }
  }

  /// Called by `DetectionRouter` after it has identified the rule and
  /// rendered the template. Drives a `.rule(id:)`-triggered transition
  /// to the rule's `transitionTo`. Separate from `ingest` because rule
  /// lookup lives in the router, not the tracker.
  @discardableResult
  func applyRuleTransition(
    to newState: AgentState,
    ruleID: String,
    now: Date = Date()
  ) -> AgentStateTransition? {
    lastActivityAt = now
    armIdleTimer()
    return transitionIfChanged(to: newState, trigger: .rule(id: ruleID), at: now)
  }

  /// Manual override from CLI/UI. Changes state but never emits a transition.
  func override(to newState: AgentState) {
    state = newState
  }

  /// Tear down the tracker: cancel the idle timer and finish the stream.
  /// Called by `TrackerRegistry` when the Panel is removed or loses its
  /// agent label; also called internally on crash/exit.
  func teardown() {
    idleTimerTask?.cancel()
    idleTimerTask = nil
    continuation.finish()
  }

  // MARK: - Private helpers

  private func transitionIfChanged(
    to newState: AgentState,
    trigger: AgentStateTransition.Trigger,
    at now: Date
  ) -> AgentStateTransition? {
    guard newState != state else { return nil }
    return emit(to: newState, trigger: trigger, at: now)
  }

  private func emit(
    to newState: AgentState,
    trigger: AgentStateTransition.Trigger,
    at now: Date
  ) -> AgentStateTransition {
    let transition = AgentStateTransition(
      panelID: panelID,
      from: state,
      to: newState,
      at: now,
      trigger: trigger
    )
    state = newState
    continuation.yield(transition)
    return transition
  }

  /// If we're in `.idle` and an activity envelope just arrived, transition
  /// back to `.running`. Otherwise no-op. Not a rule-triggered transition —
  /// labelled as `.envelope(event: .panelOutput)` since any envelope with
  /// bytes drives it.
  private func applyActivityIfNeeded(at now: Date) -> AgentStateTransition? {
    guard state == .idle else { return nil }
    return emit(to: .running, trigger: .envelope(event: .panelOutput), at: now)
  }

  private func armIdleTimer() {
    idleTimerTask?.cancel()
    let threshold = idleThreshold
    let clock = clock
    idleTimerTask = Task { [weak self] in
      do {
        try await clock.sleep(for: .seconds(threshold), tolerance: nil)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      // Double-check that no newer activity arrived during the sleep
      // (handles R1 sleep/wake: if the process was suspended then resumed,
      // `lastActivityAt` prevents a spurious firing).
      let elapsed = Date().timeIntervalSince(self.lastActivityAt)
      guard elapsed >= threshold else {
        self.armIdleTimer()
        return
      }
      _ = self.transitionIfChanged(
        to: .idle,
        trigger: .idleTimer(seconds: threshold),
        at: Date()
      )
    }
  }

  private static func isActivity(_ envelope: HookEnvelope) -> Bool {
    switch envelope.event {
    case .panelOutput, .panelOutputMatch, .panelInput:
      return true
    default:
      return false
    }
  }
}

// MARK: - Helpers

extension AgentState {
  /// On `.panelCrashed` or non-zero `.panelExited`, the FSM transitions to
  /// `.completed` so `state` reads sensibly; the accompanying `crashed`
  /// notification kind is chosen by the coordinator based on the trigger.
  fileprivate static func crashedTarget(from _: AgentState) -> AgentState { .completed }
}
