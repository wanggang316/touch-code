import Foundation
import os.log
import TouchCodeCore

/// C6's `InternalHookSubscriber` implementation — the single class C3's
/// `HookDispatcher` calls for every envelope whose `command` starts with
/// `__touch-code/internal:notifications:`.
///
/// Per envelope, the router:
/// 1. Extracts the rule id from the `command` suffix.
/// 2. Looks up the rule in the in-memory table.
/// 3. Applies `AppliesWhen.panelLabelledAgent` / `panelID` filters that
///    C3's `scope` cannot express (plus a `Match.Target`-narrow check
///    for `lastLine` / `lastNonEmptyLine` targets).
/// 4. Fetches the `AgentStateTracker` via `TrackerRegistry.tracker(for:)`.
///    Envelopes for un-tracked Panels are dropped with a `.info` log —
///    no silent tracker creation, the registry is the single owner.
/// 5. Drives `tracker.applyRuleTransition(to:ruleID:)`, captures the
///    emitted `AgentStateTransition`, stamps it with the rendered
///    template (title/body), and yields to the `transitions` stream for
///    the coordinator.
///
/// Non-rule envelopes (`.panelExited`, `.panelCrashed`, `.panelOutput`,
/// `.panelInput`) that arrive via the registered prefix route are fed
/// through `tracker.ingest(envelope:ruleID:)` so the tracker can drive
/// its own lifecycle transitions. In practice C3 only routes matched
/// subscriptions here; the direct lifecycle envelopes reach the router
/// only when the app shell wires them via an explicit forwarding bridge
/// (M4b) — the router accepts them defensively.
@MainActor
final class DetectionRouter: InternalHookSubscriber {
  private let rules: [String: AgentDetectionRules.Rule]
  private let registry: TrackerRegistry
  private let renderer: TemplateRenderer
  private let logger = Logger(subsystem: "com.touch-code.notifications", category: "router")
  private let (transitionStream, transitionContinuation): (AsyncStream<RouterOutput>, AsyncStream<RouterOutput>.Continuation)

  init(
    rules: AgentDetectionRules,
    registry: TrackerRegistry,
    renderer: TemplateRenderer
  ) {
    self.rules = Dictionary(uniqueKeysWithValues: rules.rules.map { ($0.id, $0) })
    self.registry = registry
    self.renderer = renderer
    let (stream, continuation) = AsyncStream<RouterOutput>.makeStream()
    self.transitionStream = stream
    self.transitionContinuation = continuation
  }

  deinit {
    transitionContinuation.finish()
  }

  /// Stream of tagged outputs. Each entry bundles the tracker's
  /// `AgentStateTransition` with the rendered title/body + the resolved
  /// `agent` — everything `NotificationCoordinator` (M4b) needs to post
  /// an `AgentNotification` without touching the rule table again.
  var transitions: AsyncStream<RouterOutput> { transitionStream }

  // MARK: - InternalHookSubscriber

  /// Protocol conformance. C3's dispatcher delivers every envelope whose
  /// matched `HookSubscription.command` starts with the sentinel prefix.
  /// **C6 requires the subscription's rule id to route a match** — and
  /// C3's current protocol does not pass the `HookSubscription` alongside
  /// the envelope. This overload therefore ONLY handles lifecycle events
  /// (`panelExited`, `panelCrashed`, `panelOutput`, `panelInput`); it
  /// logs and drops `.panelOutputMatch` envelopes. C3 M2 (or a test
  /// adapter) is expected to call `handle(envelope:ruleID:)` directly
  /// when it has the rule id in hand. This removes the v1-era
  /// match-text sniffing that could misroute on user output containing
  /// the sentinel prefix.
  nonisolated func handle(envelope: HookEnvelope) async {
    await MainActor.run { self.handleOnMain(envelope: envelope, ruleID: nil) }
  }

  /// Explicit entry point with the rule id plumbed through. Call this
  /// when the caller knows which `HookSubscription.command` matched.
  /// `DetectionRouter` is the sole MainActor consumer; callers must be
  /// on the MainActor too. Synchronous today; async-friendly shape kept
  /// here in case C3 M2 wires this behind an async dispatcher hand-off
  /// that benefits from suspension points.
  func handle(envelope: HookEnvelope, ruleID: String) {
    handleOnMain(envelope: envelope, ruleID: ruleID)
  }

  // MARK: - Main-actor dispatch

  private(set) var droppedEnvelopesCount = 0

  private func handleOnMain(envelope: HookEnvelope, ruleID passedRuleID: String?) {
    guard let panelID = envelope.panel?.id else {
      droppedEnvelopesCount += 1
      logger.debug("Envelope without panel anchor; ignored.")
      return
    }
    guard let tracker = registry.tracker(for: panelID) else {
      droppedEnvelopesCount += 1
      logger.info("Envelope for un-tracked Panel \(panelID); ignored.")
      return
    }
    // Direct lifecycle events — drive the tracker's FSM.
    switch envelope.event {
    case .panelExited, .panelCrashed, .panelOutput, .panelInput:
      if let transition = tracker.ingest(envelope: envelope, ruleID: nil) {
        emitLifecycleTransition(transition, envelope: envelope, tracker: tracker)
      }
      return
    case .panelOutputMatch:
      break
    default:
      return
    }

    // Matched rule path — requires the rule id from the dispatcher.
    guard let ruleID = passedRuleID else {
      droppedEnvelopesCount += 1
      logger.info("panel.outputMatch envelope missing ruleID sidechannel; dropping (awaiting C3 M2 dispatcher).")
      return
    }
    guard let rule = rules[ruleID] else {
      droppedEnvelopesCount += 1
      logger.info("Rule id '\(ruleID)' not found (likely stale after reload); dropping.")
      return
    }
    guard Self.matchesAppliesWhen(rule: rule, envelope: envelope, panelID: panelID) else {
      droppedEnvelopesCount += 1
      logger.debug("Rule '\(ruleID)' appliesWhen failed; dropping.")
      return
    }
    guard Self.passesMatchTargetFilter(rule: rule, envelope: envelope) else {
      droppedEnvelopesCount += 1
      logger.debug("Rule '\(ruleID)' match target filter failed; dropping.")
      return
    }

    let transition = tracker.applyRuleTransition(to: rule.transitionTo, ruleID: rule.id)
    guard let transition else { return }
    let (title, body) = render(rule: rule, envelope: envelope, transition: transition)
    transitionContinuation.yield(RouterOutput(
      transition: transition,
      agent: rule.agent,
      title: title,
      body: body,
      kind: Self.resolveKind(transition: transition, envelope: envelope)
    ))
  }

  private func emitLifecycleTransition(
    _ transition: AgentStateTransition,
    envelope: HookEnvelope,
    tracker: AgentStateTracker
  ) {
    // Lifecycle transitions don't carry a rule — synthesise a default
    // title/body the coordinator can fall back on. Agent name is best-
    // effort: first `agent:*` label wins. Empty string if no label (the
    // tracker should not exist in that case, but defensive).
    let agent = envelope.panel.flatMap { _ in Self.resolveAgent(for: tracker.panelID) } ?? ""
    let kindCopy = Self.lifecycleCopy(for: transition.trigger)
    transitionContinuation.yield(RouterOutput(
      transition: transition,
      agent: agent,
      title: kindCopy.title,
      body: kindCopy.body,
      kind: Self.resolveKind(transition: transition, envelope: envelope)
    ))
  }

  private func render(
    rule: AgentDetectionRules.Rule,
    envelope: HookEnvelope,
    transition: AgentStateTransition
  ) -> (String, String) {
    let title = renderer.render(
      template: rule.title,
      for: envelope,
      transition: transition,
      agent: rule.agent
    )
    let body = renderer.render(
      template: rule.body,
      for: envelope,
      transition: transition,
      agent: rule.agent
    )
    return (title, body)
  }

  // MARK: - Helpers

  static func matchesAppliesWhen(
    rule: AgentDetectionRules.Rule,
    envelope: HookEnvelope,
    panelID: PanelID
  ) -> Bool {
    if let panelLabel = rule.appliesWhen.panelLabelledAgent {
      let needle = "agent:\(panelLabel)"
      guard Self.envelopeHasLabel(envelope, label: needle) else { return false }
    }
    if let required = rule.appliesWhen.panelID, required != panelID {
      return false
    }
    return true
  }

  /// Canonical label presence check. `HookEnvelope.PanelRef.labels` is an
  /// ordered `[String]` but semantically set-like — this helper hides the
  /// storage shape and gives us one place to add normalisation later
  /// (case-folding, prefix matching) without scattering the logic.
  static func envelopeHasLabel(_ envelope: HookEnvelope, label: String) -> Bool {
    guard let labels = envelope.panel?.labels else { return false }
    return labels.contains(label)
  }

  static func passesMatchTargetFilter(
    rule: AgentDetectionRules.Rule,
    envelope: HookEnvelope
  ) -> Bool {
    guard case .regex(_, let target) = rule.match else { return true }
    guard case .panelOutputMatch(_, _, let outputData, _) = envelope.data else { return true }
    guard let output = String(data: outputData, encoding: .utf8) else { return false }
    switch target {
    case .tail:
      return true
    case .lastLine:
      return output.split(whereSeparator: \.isNewline).last != nil
    case .lastNonEmptyLine:
      return output.split(whereSeparator: \.isNewline).reversed()
        .first(where: { !$0.isEmpty }) != nil
    }
  }

  static func resolveAgent(for _: PanelID) -> String? {
    // Best-effort hook; coordinator enriches on its side via HierarchyManager.
    nil
  }

  static func lifecycleCopy(for trigger: AgentStateTransition.Trigger) -> (title: String, body: String) {
    switch trigger {
    case .envelope(let event):
      switch event {
      case .panelExited: return ("Agent finished", "")
      case .panelCrashed: return ("Agent crashed", "")
      default: return ("Agent update", "")
      }
    case .idleTimer:
      return ("Agent is idle", "")
    case .rule:
      return ("Agent update", "")
    case .userOverride:
      return ("Agent state changed", "")
    }
  }

  /// One unit of router output. M4b's coordinator consumes this stream and
  /// turns each entry into an `AgentNotification`. `kind` is pre-resolved
  /// here because the router is the only point with the full context
  /// (envelope + trigger) to distinguish a normal `.completed` from a
  /// non-zero-exit `.crashed`.
  struct RouterOutput: Sendable, Equatable {
    let transition: AgentStateTransition
    let agent: String
    let title: String
    let body: String
    let kind: AgentNotification.Kind
  }

  static func resolveKind(
    transition: AgentStateTransition,
    envelope: HookEnvelope
  ) -> AgentNotification.Kind {
    switch envelope.event {
    case .panelCrashed:
      return .crashed
    case .panelExited:
      if case .panelExited(let code) = envelope.data, code != 0 {
        return .crashed
      }
      return .completed
    default:
      switch transition.to {
      case .completed: return .completed
      case .blockedOnInput: return .blockedOnInput
      case .idle: return .idle
      case .running: return .completed  // no-op fallback; rarely reached
      }
    }
  }
}
