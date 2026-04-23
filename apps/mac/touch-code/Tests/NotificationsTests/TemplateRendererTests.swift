import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

struct TemplateRendererTests {
  // MARK: - Init validation

  @Test
  func unknownFieldPathThrowsAtInit() {
    let rules = Self.rules(title: "{no.such.field}")
    #expect(throws: RuleStoreError.self) {
      _ = try TemplateRenderer(rules: rules)
    }
  }

  @Test
  func unknownFilterThrowsAtInit() {
    let rules = Self.rules(title: "{agent | mysteryFilter}")
    #expect(throws: RuleStoreError.self) {
      _ = try TemplateRenderer(rules: rules)
    }
  }

  @Test
  func fieldFromDifferentEventTypeThrowsAtInit() {
    // data.idleSeconds isn't valid for paneOutputMatch rules.
    let rules = Self.rules(
      hookEvent: .paneOutputMatch,
      title: "Idle for {data.idleSeconds}"
    )
    #expect(throws: RuleStoreError.self) {
      _ = try TemplateRenderer(rules: rules)
    }
  }

  // MARK: - Resolution

  @Test
  func simpleFieldRenders() throws {
    let renderer = try TemplateRenderer(rules: Self.rules(title: "{agent}"))
    let output = renderer.render(
      template: "{agent}",
      for: Self.envelope(),
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "claude")
  }

  @Test
  func templateWithLiteralTextRenders() throws {
    let renderer = try TemplateRenderer(rules: Self.rules(title: "Claude finished"))
    let output = renderer.render(
      template: "Agent {agent} finished",
      for: Self.envelope(),
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "Agent claude finished")
  }

  @Test
  func firstLineFilterDropsSubsequentLines() throws {
    let renderer = try TemplateRenderer(rules: Self.rules(title: "{data.output | firstLine}"))
    let multiline = Data("first\nsecond\nthird".utf8)
    let envelope = Self.envelope(
      data: .paneOutputMatch(
        match: "first", matchedRange: HookMatchRange(start: 0, length: 5), output: multiline,
        outputBytes: multiline.count)
    )
    let output = renderer.render(
      template: "{data.output | firstLine}",
      for: envelope,
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "first")
  }

  @Test
  func truncateFilterClampsGraphemeCount() throws {
    let rules = Self.rules(title: "{data.output | truncate: 5}")
    let renderer = try TemplateRenderer(rules: rules)
    let data = Data("Hello, world!".utf8)
    let envelope = Self.envelope(
      data: .paneOutputMatch(
        match: "Hello", matchedRange: HookMatchRange(start: 0, length: 5), output: data, outputBytes: data.count)
    )
    let output = renderer.render(
      template: "{data.output | truncate: 5}",
      for: envelope,
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "Hello")
  }

  @Test
  func defaultFilterKicksInWhenEmpty() throws {
    let rules = Self.rules(title: "{worktree.branch | default: \"main\"}")
    let renderer = try TemplateRenderer(rules: rules)
    let envelope = Self.envelope()  // worktree branch is nil/empty
    let output = renderer.render(
      template: "{worktree.branch | default: \"main\"}",
      for: envelope,
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "main")
  }

  @Test
  func upperFilterUppercases() throws {
    let rules = Self.rules(title: "{agent | upper}")
    let renderer = try TemplateRenderer(rules: rules)
    let output = renderer.render(
      template: "{agent | upper}",
      for: Self.envelope(),
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "CLAUDE")
  }

  @Test
  func chainedFiltersLeftToRight() throws {
    let rules = Self.rules(title: "{data.output | firstLine | truncate: 3}")
    let renderer = try TemplateRenderer(rules: rules)
    let data = Data("Hello\nworld".utf8)
    let envelope = Self.envelope(
      data: .paneOutputMatch(
        match: "x", matchedRange: HookMatchRange(start: 0, length: 1), output: data, outputBytes: data.count)
    )
    let output = renderer.render(
      template: "{data.output | firstLine | truncate: 3}",
      for: envelope,
      transition: Self.transition(),
      agent: "claude"
    )
    #expect(output == "Hel")
  }

  // MARK: - Helpers

  private static func rules(
    hookEvent: HookEvent = .paneOutputMatch,
    title: String = "{agent}",
    body: String = "b"
  ) -> AgentDetectionRules {
    AgentDetectionRules(
      idleThresholdSeconds: 120,
      rules: [
        AgentDetectionRules.Rule(
          id: "test.rule",
          agent: "claude",
          appliesWhen: .init(hookEvent: hookEvent),
          match: hookEvent == .paneOutputMatch ? .containsAny(["x"]) : nil,
          transitionTo: .completed,
          title: title,
          body: body
        )
      ]
    )
  }

  private static func envelope(
    data: HookEventData = .paneOutputMatch(
      match: "x", matchedRange: HookMatchRange(start: 0, length: 1), output: Data(), outputBytes: 0)
  ) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: .paneOutputMatch,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      pane: HookEnvelope.PaneRef(
        id: PaneID(),
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: []
      ),
      data: data
    )
  }

  private static func transition() -> AgentStateTransition {
    AgentStateTransition(
      paneID: PaneID(),
      from: .running,
      to: .completed,
      at: Date(),
      trigger: .rule(id: "test.rule")
    )
  }
}
