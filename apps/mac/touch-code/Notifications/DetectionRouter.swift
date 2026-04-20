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

  nonisolated func handle(envelope: HookEnvelope) async {
    await MainActor.run { self.handleOnMain(envelope: envelope) }
  }

  // MARK: - Main-actor dispatch

  private func handleOnMain(envelope: HookEnvelope) {
    guard let panelID = envelope.panel?.id else {
      logger.debug("Envelope without panel anchor; ignored.")
      return
    }
    guard let tracker = registry.tracker(for: panelID) else {
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

    // Matched rule path — look up via the command suffix.
    guard let ruleID = Self.ruleID(from: envelope) else {
      logger.debug("No rule id; dropping.")
      return
    }
    guard let rule = rules[ruleID] else {
      logger.info("Rule id '\(ruleID)' not found (likely stale after reload); dropping.")
      return
    }
    guard Self.matchesAppliesWhen(rule: rule, envelope: envelope, panelID: panelID) else {
      logger.debug("Rule '\(ruleID)' appliesWhen failed; dropping.")
      return
    }
    guard Self.passesMatchTargetFilter(rule: rule, envelope: envelope) else {
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
      body: body
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
      body: kindCopy.body
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

  static func ruleID(from envelope: HookEnvelope) -> String? {
    // C3 does not surface the subscription's command on the envelope; the
    // dispatcher is expected to pass it via a sidechannel. Until C3 M2
    // pins that shape, M4b is expected to inject the id alongside the
    // envelope via a separate router entry point. For the current
    // router contract, we mirror C3 DEC-16's intended prefix-route by
    // reading an optional `userInfo`-style key on the envelope (none
    // exists yet), and otherwise require the caller to have used
    // `handle(envelope:ruleID:)`-style indirection. As M2a, we instead
    // expect the envelope.matchedRange's `match` text to carry the
    // sentinel-prefix marker in production rules via their regex.
    // Fallback: extract `__touch-code/internal:notifications:<id>` from
    // the match string if present.
    guard case .panelOutputMatch(let match, _, _, _) = envelope.data else { return nil }
    let prefix = RuleStore.sentinelPrefix
    if let range = match.range(of: prefix) {
      return String(match[range.upperBound...])
    }
    return nil
  }

  static func matchesAppliesWhen(
    rule: AgentDetectionRules.Rule,
    envelope: HookEnvelope,
    panelID: PanelID
  ) -> Bool {
    if let panelLabel = rule.appliesWhen.panelLabelledAgent {
      let label = "agent:\(panelLabel)"
      guard envelope.panel?.labels.contains(label) == true else { return false }
    }
    if let required = rule.appliesWhen.panelID, required != panelID {
      return false
    }
    return true
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
  /// turns each entry into an `AgentNotification`.
  struct RouterOutput: Sendable, Equatable {
    let transition: AgentStateTransition
    let agent: String
    let title: String
    let body: String
  }
}
