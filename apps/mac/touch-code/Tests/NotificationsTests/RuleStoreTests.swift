import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct RuleStoreTests {
  @Test
  func loadOfMissingFileYieldsEmptyAndClearsInternalSubs() throws {
    let url = Self.tempURL()
    let writer = FakeHookConfigWriter()
    let store = RuleStore(fileURL: url, hookWriter: writer)
    let rules = try store.loadAndMaterialise()
    #expect(rules.rules.isEmpty)
    // With zero rules we only strip the prefix; no upsert call.
    #expect(writer.removeInternalCalls == [RuleStore.sentinelPrefix])
    #expect(writer.upsertInternalCalls.isEmpty)
  }

  @Test
  func materialiseUpsertsSentinelSubscriptions() throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let rules = AgentDetectionRules(
      idleThresholdSeconds: 120,
      rules: [
        AgentDetectionRules.Rule(
          id: "claude.blocked",
          agent: "claude",
          appliesWhen: .init(panelLabelledAgent: "claude", hookEvent: .panelOutputMatch),
          match: .containsAny(["Do you want to proceed?"]),
          transitionTo: .blockedOnInput,
          title: "Claude is waiting",
          body: "prompt"
        )
      ]
    )
    try AtomicFileStore.write(rules, to: url)

    let writer = FakeHookConfigWriter()
    let store = RuleStore(fileURL: url, hookWriter: writer)
    _ = try store.loadAndMaterialise()

    // Remove stripped then upsert once with the single rule.
    #expect(writer.removeInternalCalls == [RuleStore.sentinelPrefix])
    #expect(writer.upsertInternalCalls.count == 1)
    let upserted = try #require(writer.upsertInternalCalls.first)
    #expect(upserted.count == 1)
    let sub = try #require(upserted.first)
    #expect(sub.command == "\(RuleStore.sentinelPrefix)claude.blocked")
    #expect(sub.event == .panelOutputMatch)
  }

  @Test
  func reloadStripsBeforeInsertingNewSet() throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let rules = AgentDetectionRules(
      idleThresholdSeconds: 120,
      rules: [
        AgentDetectionRules.Rule(
          id: "claude.blocked",
          agent: "claude",
          appliesWhen: .init(panelLabelledAgent: "claude", hookEvent: .panelOutputMatch),
          match: .regex(pattern: "foo", on: .tail),
          transitionTo: .blockedOnInput,
          title: "t",
          body: "b"
        )
      ]
    )
    try AtomicFileStore.write(rules, to: url)

    let writer = FakeHookConfigWriter()
    let store = RuleStore(fileURL: url, hookWriter: writer)
    _ = try store.loadAndMaterialise()
    // Call again — second materialise must strip + re-upsert without
    // relying on any local filtering.
    _ = try store.loadAndMaterialise()

    #expect(writer.removeInternalCalls.count == 2)
    #expect(writer.upsertInternalCalls.count == 2)
    let second = try #require(writer.upsertInternalCalls.last)
    #expect(second.count == 1)
    #expect(second[0].command == "\(RuleStore.sentinelPrefix)claude.blocked")
  }

  @Test
  func invalidRegexThrowsAndSkipsUpsert() throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let rules = AgentDetectionRules(
      idleThresholdSeconds: 120,
      rules: [
        AgentDetectionRules.Rule(
          id: "bad.regex",
          agent: "x",
          appliesWhen: .init(hookEvent: .panelOutputMatch),
          match: .regex(pattern: "[unclosed", on: .tail),
          transitionTo: .completed,
          title: "t",
          body: "b"
        )
      ]
    )
    try AtomicFileStore.write(rules, to: url)

    let writer = FakeHookConfigWriter()
    let store = RuleStore(fileURL: url, hookWriter: writer)
    #expect(throws: RuleStoreError.self) {
      _ = try store.loadAndMaterialise()
    }
    // Validation fails before materialise — no adapter calls.
    #expect(writer.removeInternalCalls.isEmpty)
    #expect(writer.upsertInternalCalls.isEmpty)
  }

  @Test
  func containsAnyBecomesAlternationRegex() throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked",
      agent: "claude",
      appliesWhen: .init(hookEvent: .panelOutputMatch),
      match: .containsAny(["Do you want to proceed?", "Approve tool call?"]),
      transitionTo: .blockedOnInput,
      title: "t",
      body: "b"
    )
    let sub = RuleStore.makeSubscription(from: rule)
    #expect(sub.matchPattern?.contains("Do you want to proceed\\?") == true)
    #expect(sub.matchPattern?.contains("|") == true)
  }

  private static func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appending(component: "rules-\(UUID().uuidString).json")
  }
}

// MARK: - Test double

@MainActor
final class FakeHookConfigWriter: HookConfigWriting {
  private(set) var upsertInternalCalls: [[HookSubscription]] = []
  private(set) var removeInternalCalls: [String] = []

  func upsertInternal(_ subscriptions: [HookSubscription]) throws {
    upsertInternalCalls.append(subscriptions)
  }

  func removeInternal(idsPrefixed prefix: String) throws {
    removeInternalCalls.append(prefix)
  }
}
