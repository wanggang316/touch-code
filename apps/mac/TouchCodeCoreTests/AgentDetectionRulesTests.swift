import Foundation
import Testing

@testable import TouchCodeCore

struct AgentDetectionRulesTests {
  @Test
  func emptyRuleSetRoundTrip() throws {
    let rules = AgentDetectionRules()
    let data = try JSONEncoder().encode(rules)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.self, from: data)
    #expect(decoded == rules)
    #expect(decoded.idleThresholdSeconds == 120)
  }

  @Test
  func populatedRulesRoundTrip() throws {
    let rule = AgentDetectionRules.Rule(
      id: "claude.blocked_on_input",
      agent: "claude",
      appliesWhen: .init(paneLabelledAgent: "claude", hookEvent: .paneOutputMatch),
      match: .containsAny(["Do you want to proceed?", "Approve tool call?"]),
      transitionTo: .blockedOnInput,
      title: "Claude is waiting",
      body: "{data.output | firstLine}"
    )
    let rules = AgentDetectionRules(idleThresholdSeconds: 60, rules: [rule])
    let data = try JSONEncoder().encode(rules)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.self, from: data)
    #expect(decoded == rules)
    #expect(decoded.rules.count == 1)
    #expect(decoded.rules[0].transitionTo == .blockedOnInput)
  }

  @Test
  func containsAnyMatchRoundTripsViaCamelCaseKey() throws {
    let match: AgentDetectionRules.Match = .containsAny(["a", "b"])
    let data = try JSONEncoder().encode(match)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"containsAny\""))
    #expect(json.contains("\"a\""))
    let decoded = try JSONDecoder().decode(AgentDetectionRules.Match.self, from: data)
    #expect(decoded == match)
  }

  @Test
  func regexMatchRoundTripsWithTarget() throws {
    let match: AgentDetectionRules.Match = .regex(pattern: "^>\\s*$", on: .lastNonEmptyLine)
    let data = try JSONEncoder().encode(match)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.Match.self, from: data)
    #expect(decoded == match)
  }

  @Test
  func regexMatchDefaultsToTailWhenOnOmitted() throws {
    // Absence of `on` decodes to the documented default `tail`.
    let payload = Data(#"{"regex": "foo"}"#.utf8)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.Match.self, from: payload)
    if case .regex(let pattern, let on) = decoded {
      #expect(pattern == "foo")
      #expect(on == .tail)
    } else {
      Issue.record("Expected .regex; got \(decoded)")
    }
  }

  @Test
  func matchWithNeitherKeyThrows() throws {
    let payload = Data(#"{}"#.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AgentDetectionRules.Match.self, from: payload)
    }
  }

  @Test
  func unknownVersionThrows() throws {
    let payload = Data(#"{"version": 99, "idleThresholdSeconds": 60, "rules": []}"#.utf8)
    #expect(throws: AgentDetectionRules.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder().decode(AgentDetectionRules.self, from: payload)
    }
  }

  @Test
  func paneOutputMatchRuleWithoutMatchThrowsMissingMatch() throws {
    // A rule scoped to .paneOutputMatch MUST carry a `match`.
    let payload = Data(#"""
    {
      "version": 1,
      "idleThresholdSeconds": 60,
      "rules": [
        {
          "id": "bad.rule",
          "agent": "x",
          "appliesWhen": { "paneLabelledAgent": "x", "hookEvent": "pane.outputMatch" },
          "transitionTo": "completed",
          "title": "t",
          "body": "b"
        }
      ]
    }
    """#.utf8)
    #expect(throws: AgentDetectionRules.DecodingIssue.missingMatch(ruleID: "bad.rule")) {
      _ = try JSONDecoder().decode(AgentDetectionRules.self, from: payload)
    }
  }

  @Test
  func nonOutputMatchRuleWithoutMatchIsFine() throws {
    // A .paneIdle-scoped rule does not require a match.
    let payload = Data(#"""
    {
      "version": 1,
      "rules": [
        {
          "id": "claude.idle",
          "agent": "claude",
          "appliesWhen": { "paneLabelledAgent": "claude", "hookEvent": "pane.idle" },
          "transitionTo": "idle",
          "title": "Idle",
          "body": "Nothing for a while"
        }
      ]
    }
    """#.utf8)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.self, from: payload)
    #expect(decoded.rules.count == 1)
    #expect(decoded.rules[0].appliesWhen.hookEvent == .paneIdle)
  }

  @Test
  func missingIdleThresholdDefaultsTo120() throws {
    let payload = Data(#"{"version": 1, "rules": []}"#.utf8)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.self, from: payload)
    #expect(decoded.idleThresholdSeconds == 120)
  }
}
