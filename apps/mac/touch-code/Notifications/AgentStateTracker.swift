import Foundation
import Observation
import TouchCodeCore

/// Per-Pane FSM for one agent-hosted Pane. Exactly one instance exists per
/// tracked Pane, owned by `TrackerRegistry`. Callers drive the FSM by
/// feeding C3 `HookEnvelope`s (plus the optional `ruleID` and rendered
/// template strings that `DetectionRouter` resolves); the tracker emits
/// `AgentStateTransition`s whenever the state changes, and an idle-timer
/// fires a local `.idle` transition after `idleThreshold` seconds of
/// silence (design §FSM Transition Table).
///
/// Notification emission invariants:
/// - Self-transitions (`from == to`) do not emit a transition.
/// - `.paneCrashed` always emits a `.crashed`-class transition (even
///   when already in `.completed`) and then tears down.
/// - `userOverride` may set any state but never emits a transition —
///   it is a correction, not an event.
@MainActor
@Observable
final class AgentStateTracker {
  let paneID: PaneID
  private(set) var state: AgentState = .running
  private(set) var lastActivityAt: Date

  private(set) var idleThreshold: TimeInterval
  private let clock: any Clock<Duration>

  /// Most recent user keystroke on this pane. The tracker suppresses
  /// `.completed` (rule-driven) and `.idle` (timer) transitions for
  /// `userInteractionWindow` seconds after this stamps; lifecycle events
  /// (`.paneExited`, `.paneCrashed`) always notify, since they're rare
  /// and important enough to interrupt typing. v2 D4 / DEC-V4.
  private var lastUserInputAt: Date?
  private let userInteractionWindow: TimeInterval = 3.0
  private let (continuation, stream):
    (AsyncStream<AgentStateTransition>.Continuation, AsyncStream<AgentStateTransition>)
  /// `Task` is `Sendable` and `cancel()` is safe from any context. We
  /// store the handle `nonisolated(unsafe)` so `deinit` can cancel
  /// the pending sleep without hopping to `MainActor`. Mutations stay
  /// on `MainActor` (only `armIdleTimer()` / `teardown()` write).
  private nonisolated(unsafe) var idleTimerTask: Task<Void, Never>?

  init(
    paneID: PaneID,
    idleThreshold: TimeInterval,
    clock: any Clock<Duration> = ContinuousClock(),
    now: Date = Date()
  ) {
    self.paneID = paneID
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
    // `Task.cancel()` is safe from any context (Task is Sendable), and
    // `idleTimerTask` is stored `nonisolated(unsafe)` precisely so this
    // nonisolated deinit can cancel the pending sleep without hopping to
    // the MainActor. Cancellation plus `continuation.finish()` releases
    // both the timer and any stream consumer immediately on drop-out.
    idleTimerTask?.cancel()
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
    case .paneCrashed:
      let transition = emit(to: .crashedTarget(from: state), trigger: .envelope(event: .paneCrashed), at: now)
      teardown()
      return transition

    case .paneExited:
      if case .paneExited(let code) = envelope.data, code == 0 {
        return transitionIfChanged(to: .completed, trigger: .envelope(event: .paneExited), at: now)
      } else {
        // Non-zero exit is a crash-like signal — emit a crashed transition then teardown.
        let transition = emit(to: .crashedTarget(from: state), trigger: .envelope(event: .paneExited), at: now)
        teardown()
        return transition
      }

    case .paneOutputMatch:
      // Rule lookup + state transition happens in DetectionRouter via
      // applyRuleTransition(to:ruleID:). This branch is a no-op so that
      // a router delegating every envelope still gets the activity timer
      // rearm handled above.
      _ = ruleID
      return nil

    case .paneOutput:
      // Activity already handled above; if we were idle, we've moved to
      // .running via `applyActivityIfNeeded`. No further transition.
      return applyActivityIfNeeded(at: now)

    case .paneInput:
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

  /// Record a user keystroke. The next `.completed`/`.idle` transition
  /// within `userInteractionWindow` seconds will update `state` but not
  /// yield to the transitions stream — so the user does not get a
  /// notification banner for a pane they are actively typing in.
  /// Lifecycle envelopes (`.paneExited`, `.paneCrashed`) are not
  /// suppressed; user override is irrelevant per design invariant.
  func recordUserInput(at: Date = Date()) {
    lastUserInputAt = at
  }

  /// Adopt a new idle threshold without resetting the FSM. Driven by
  /// `RuleStore.reloadAndRematerialise()` so a user who edits
  /// `detection-rules.json` and runs reload sees the change reflected
  /// in still-running Panes; the timer re-arms against the new value.
  /// Does NOT change `state` — current agent state is a property of the
  /// agent, not of the rules.
  func updateIdleThreshold(_ seconds: TimeInterval) {
    guard seconds != idleThreshold else { return }
    idleThreshold = seconds
    armIdleTimer()
  }

  /// Tear down the tracker: cancel the idle timer and finish the stream.
  /// Called by `TrackerRegistry` when the Pane is removed or loses its
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
      paneID: paneID,
      from: state,
      to: newState,
      at: now,
      trigger: trigger
    )
    // State advances even when the transition is suppressed for the
    // user-interaction window. Two consequences worth knowing:
    // - A `.completed` suppressed inside the window leaves the FSM at
    //   `.completed` — a subsequent rule-driven `.completed` is a
    //   self-transition and `transitionIfChanged` will drop it. This is
    //   intended: the user was actively typing in the pane the moment
    //   the agent finished, so they already know; skipping the would-be
    //   second banner avoids re-notifying for the same event.
    // - A `.idle` suppressed inside the window self-corrects on the
    //   next byte: `applyActivityIfNeeded` flips `.idle → .running`,
    //   re-arming the timer, so the next quiet stretch fires a fresh
    //   `.idle` outside the suppression window.
    state = newState
    if !shouldSuppress(transition, now: now) {
      continuation.yield(transition)
    }
    return transition
  }

  /// True iff the transition lands within the user-interaction window
  /// AND the transition kind is one that notifies (rule-driven
  /// completion, timer-driven idle). Lifecycle envelopes always notify
  /// — see the `lastUserInputAt` doc-comment for rationale.
  private func shouldSuppress(_ transition: AgentStateTransition, now: Date) -> Bool {
    guard let last = lastUserInputAt else { return false }
    guard now.timeIntervalSince(last) < userInteractionWindow else { return false }
    switch transition.trigger {
    case .rule:
      return transition.to == .completed
    case .idleTimer:
      return true
    case .envelope, .userOverride:
      return false
    }
  }

  /// If we're in `.idle` and an activity envelope just arrived, transition
  /// back to `.running`. Otherwise no-op. Not a rule-triggered transition —
  /// labelled as `.envelope(event: .paneOutput)` since any envelope with
  /// bytes drives it.
  private func applyActivityIfNeeded(at now: Date) -> AgentStateTransition? {
    guard state == .idle else { return nil }
    return emit(to: .running, trigger: .envelope(event: .paneOutput), at: now)
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
    case .paneOutput, .paneOutputMatch, .paneInput:
      return true
    default:
      return false
    }
  }
}

// MARK: - Helpers

extension AgentState {
  /// On `.paneCrashed` or non-zero `.paneExited`, the FSM transitions to
  /// `.completed` so `state` reads sensibly; the accompanying `crashed`
  /// notification kind is chosen by the coordinator based on the trigger.
  fileprivate static func crashedTarget(from _: AgentState) -> AgentState { .completed }
}
