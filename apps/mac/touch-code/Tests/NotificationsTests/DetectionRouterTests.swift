import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

@MainActor
struct DetectionRouterTests {
  @Test
  func handleEmitsTransitionForMatchedRule() async throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(panelLabelledAgent: "claude", hookEvent: .panelOutputMatch),
      match: .containsAny(["x"]),
      transitionTo: .blockedOnInput,
      title: "Claude is waiting",
      body: "prompt"
    )
    let rules = AgentDetectionRules(rules: [rule])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let panelID = PanelID()
    _ = registry.create(for: panelID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    var iterator = router.transitions.makeAsyncIterator()

    // Explicit ruleID seam — the new M2-fix API. C3 M2 is expected to
    // call this overload once its dispatcher can plumb the sidechannel.
    let envelope = Self.envelope(
      panelID: panelID,
      labels: ["agent:claude"],
      match: "matched text"
    )
    await router.handle(envelope: envelope, ruleID: "claude.blocked")
    let output = await iterator.next()
    #expect(output?.transition.to == .blockedOnInput)
    #expect(output?.transition.trigger == .rule(id: "claude.blocked"))
    #expect(output?.agent == "claude")
    #expect(output?.title == "Claude is waiting")
  }

  @Test
  func handleDropsEnvelopeForUnTrackedPanel() async throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(panelLabelledAgent: "claude", hookEvent: .panelOutputMatch),
      match: .containsAny(["x"]),
      transitionTo: .blockedOnInput,
      title: "t", body: "b"
    )
    let rules = AgentDetectionRules(rules: [rule])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()  // no trackers
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    let before = router.droppedEnvelopesCount

    let envelope = Self.envelope(
      panelID: PanelID(),
      labels: ["agent:claude"],
      match: "\(RuleStore.sentinelPrefix)claude.blocked"
    )
    await router.handle(envelope: envelope, ruleID: "claude.blocked")

    // The router exposes a counter for observability — no tracker means
    // the envelope is logged and counted as dropped.
    #expect(router.droppedEnvelopesCount == before + 1)
  }

  @Test
  func panelOutputMatchWithoutRuleIDIsCountedDropped() async throws {
    // The protocol-compliant `handle(envelope:)` path has no ruleID; it
    // must log-and-drop .panelOutputMatch envelopes (until C3 M2 plumbs
    // the ruleID sidechannel).
    let rules = AgentDetectionRules(rules: [])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let panelID = PanelID()
    _ = registry.create(for: panelID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    let before = router.droppedEnvelopesCount
    let envelope = Self.envelope(
      panelID: panelID,
      labels: ["agent:claude"],
      match: "whatever"
    )
    await router.handle(envelope: envelope)
    #expect(router.droppedEnvelopesCount == before + 1)
  }

  @Test
  func panelLabelFilterRejectsNonMatchingLabels() async throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(panelLabelledAgent: "claude", hookEvent: .panelOutputMatch),
      match: .containsAny(["x"]),
      transitionTo: .blockedOnInput,
      title: "t", body: "b"
    )
    let rules = AgentDetectionRules(rules: [rule])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let panelID = PanelID()
    _ = registry.create(for: panelID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)

    // Panel carries a different agent label → appliesWhen should reject.
    let envelope = Self.envelope(
      panelID: panelID,
      labels: ["agent:codex"],
      match: "whatever"
    )
    await router.handle(envelope: envelope, ruleID: "claude.blocked")
    // Tracker state should remain .running — the transition never applied.
    let tracker = try #require(registry.tracker(for: panelID))
    #expect(tracker.state == .running)
  }

  @Test
  func panelExitedEnvelopeFlowsDirectToTracker() async throws {
    let rules = AgentDetectionRules(rules: [])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let panelID = PanelID()
    _ = registry.create(for: panelID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    var iterator = router.transitions.makeAsyncIterator()

    let envelope = Self.envelopeExited(panelID: panelID, exitCode: 0)
    await router.handle(envelope: envelope)

    let output = await iterator.next()
    #expect(output?.transition.to == .completed)
    #expect(output?.transition.trigger == .envelope(event: .panelExited))
  }

  // MARK: - Helpers

  private static func emptyRegistry() -> TrackerRegistry {
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    let store = CatalogStore(fileURL: tempURL)
    let hierarchy = HierarchyManager(catalog: .default, store: store, runtime: FakeHierarchyRuntime())
    return TrackerRegistry(hierarchy: hierarchy, idleThreshold: 120)
  }

  private static func envelope(panelID: PanelID, labels: [String], match: String) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: .panelOutputMatch,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      panel: HookEnvelope.PanelRef(
        id: panelID,
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: labels
      ),
      data: .panelOutputMatch(
        match: match,
        matchedRange: HookMatchRange(start: 0, length: match.count),
        output: Data(match.utf8),
        outputBytes: match.count
      )
    )
  }

  private static func envelopeExited(panelID: PanelID, exitCode: Int32) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: .panelExited,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      panel: HookEnvelope.PanelRef(
        id: panelID,
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: []
      ),
      data: .panelExited(exitCode: exitCode)
    )
  }
}
