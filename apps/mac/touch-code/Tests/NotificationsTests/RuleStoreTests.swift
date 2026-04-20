import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

@MainActor
struct RuleStoreTests {
  @Test
  func loadOfMissingFileReturnsEmptyRules() throws {
    let url = Self.tempURL()
    let writer = FakeHookConfigWriter()
    let store = RuleStore(fileURL: url, hookWriter: writer)
    let rules = try store.loadAndMaterialise()
    #expect(rules.rules.isEmpty)
    // Still calls save (strips any prior sentinel subs + adds none).
    #expect(writer.saveCalls == 1)
  }

  @Test
  func materialiseAddsSentinelSubscriptionsAndPreservesOthers() throws {
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
        ),
      ]
    )
    try AtomicFileStore.write(rules, to: url)

    // Writer pre-loaded with an unrelated user subscription.
    let userSub = HookSubscription(event: .panelIdle, command: "~/bin/notify")
    let writer = FakeHookConfigWriter()
    writer.config.subscriptions = [userSub]

    let store = RuleStore(fileURL: url, hookWriter: writer)
    _ = try store.loadAndMaterialise()

    let saved = writer.config.subscriptions
    let userSurvived = saved.contains { $0.id == userSub.id }
    let newSentinel = saved.contains { $0.command.hasPrefix(RuleStore.sentinelPrefix) }
    #expect(userSurvived)
    #expect(newSentinel)
    #expect(saved.count == 2)
  }

  @Test
  func reloadRematerialiseStripsOldSentinelsBeforeAdding() throws {
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
        ),
      ]
    )
    try AtomicFileStore.write(rules, to: url)

    // Seed writer with an existing C6 sentinel (from a prior load).
    let stale = HookSubscription(
      event: .panelOutputMatch,
      command: "\(RuleStore.sentinelPrefix)old.rule"
    )
    let writer = FakeHookConfigWriter()
    writer.config.subscriptions = [stale]

    let store = RuleStore(fileURL: url, hookWriter: writer)
    _ = try store.loadAndMaterialise()

    let sentinels = writer.config.subscriptions.filter {
      $0.command.hasPrefix(RuleStore.sentinelPrefix)
    }
    #expect(sentinels.count == 1)
    #expect(sentinels[0].command == "\(RuleStore.sentinelPrefix)claude.blocked")
  }

  @Test
  func invalidRegexThrows() throws {
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
        ),
      ]
    )
    try AtomicFileStore.write(rules, to: url)

    let writer = FakeHookConfigWriter()
    let store = RuleStore(fileURL: url, hookWriter: writer)
    #expect(throws: RuleStoreError.self) {
      _ = try store.loadAndMaterialise()
    }
    // No save happened because validate failed before materialise.
    #expect(writer.saveCalls == 0)
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
  var config = HookConfig.empty
  var loadCalls = 0
  var saveCalls = 0

  func load() throws -> HookConfig {
    loadCalls += 1
    return config
  }

  func save(_ config: HookConfig) throws {
    saveCalls += 1
    self.config = config
  }
}
