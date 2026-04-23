import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct DetectionRouterTests {
  @Test
  func handleEmitsTransitionForMatchedRule() async throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(paneLabelledAgent: "claude", hookEvent: .paneOutputMatch),
      match: .containsAny(["x"]),
      transitionTo: .blockedOnInput,
      title: "Claude is waiting",
      body: "prompt"
    )
    let rules = AgentDetectionRules(rules: [rule])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let paneID = PaneID()
    _ = registry.create(for: paneID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    var iterator = router.transitions.makeAsyncIterator()

    // Explicit ruleID seam — the new M2-fix API. C3 M2 is expected to
    // call this overload once its dispatcher can plumb the sidechannel.
    let envelope = Self.envelope(
      paneID: paneID,
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
  func handleDropsEnvelopeForUnTrackedPane() async throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(paneLabelledAgent: "claude", hookEvent: .paneOutputMatch),
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
      paneID: PaneID(),
      labels: ["agent:claude"],
      match: "\(RuleStore.sentinelPrefix)claude.blocked"
    )
    await router.handle(envelope: envelope, ruleID: "claude.blocked")

    // The router exposes a counter for observability — no tracker means
    // the envelope is logged and counted as dropped.
    #expect(router.droppedEnvelopesCount == before + 1)
  }

  @Test
  func paneOutputMatchWithoutRuleIDIsCountedDropped() async throws {
    // The protocol-compliant `handle(envelope:)` path has no ruleID; it
    // must log-and-drop .paneOutputMatch envelopes (until C3 M2 plumbs
    // the ruleID sidechannel).
    let rules = AgentDetectionRules(rules: [])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let paneID = PaneID()
    _ = registry.create(for: paneID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    let before = router.droppedEnvelopesCount
    let envelope = Self.envelope(
      paneID: paneID,
      labels: ["agent:claude"],
      match: "whatever"
    )
    await router.handle(envelope: envelope)
    #expect(router.droppedEnvelopesCount == before + 1)
  }

  @Test
  func paneLabelFilterRejectsNonMatchingLabels() async throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(paneLabelledAgent: "claude", hookEvent: .paneOutputMatch),
      match: .containsAny(["x"]),
      transitionTo: .blockedOnInput,
      title: "t", body: "b"
    )
    let rules = AgentDetectionRules(rules: [rule])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let paneID = PaneID()
    _ = registry.create(for: paneID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)

    // Pane carries a different agent label → appliesWhen should reject.
    let envelope = Self.envelope(
      paneID: paneID,
      labels: ["agent:codex"],
      match: "whatever"
    )
    await router.handle(envelope: envelope, ruleID: "claude.blocked")
    // Tracker state should remain .running — the transition never applied.
    let tracker = try #require(registry.tracker(for: paneID))
    #expect(tracker.state == .running)
  }

  @Test
  func paneExitedEnvelopeFlowsDirectToTracker() async throws {
    let rules = AgentDetectionRules(rules: [])
    let renderer = try TemplateRenderer(rules: rules)
    let registry = Self.emptyRegistry()
    let paneID = PaneID()
    _ = registry.create(for: paneID)
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)
    var iterator = router.transitions.makeAsyncIterator()

    let envelope = Self.envelopeExited(paneID: paneID, exitCode: 0)
    await router.handle(envelope: envelope)

    let output = await iterator.next()
    #expect(output?.transition.to == .completed)
    #expect(output?.transition.trigger == .envelope(event: .paneExited))
  }

  // MARK: - Helpers

  private static func emptyRegistry() -> TrackerRegistry {
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    let store = CatalogStore(fileURL: tempURL)
    let hierarchy = HierarchyManager(catalog: .default, store: store, runtime: FakeHierarchyRuntime())
    return TrackerRegistry(hierarchy: hierarchy, idleThreshold: 120)
  }

  private static func envelope(paneID: PaneID, labels: [String], match: String) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: .paneOutputMatch,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      pane: HookEnvelope.PaneRef(
        id: paneID,
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: labels
      ),
      data: .paneOutputMatch(
        match: match,
        matchedRange: HookMatchRange(start: 0, length: match.count),
        output: Data(match.utf8),
        outputBytes: match.count
      )
    )
  }

  private static func envelopeExited(paneID: PaneID, exitCode: Int32) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: .paneExited,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      pane: HookEnvelope.PaneRef(
        id: paneID,
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: []
      ),
      data: .paneExited(exitCode: exitCode)
    )
  }
}
