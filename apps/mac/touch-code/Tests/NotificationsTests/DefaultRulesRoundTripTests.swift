import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// M6b Codable round-trip: proves that the bundled `DefaultRules.json`
/// string decodes cleanly through `AgentDetectionRules` and re-encodes
/// to an equivalent structure. Catches drift between the JSON literal
/// in `DefaultRules.swift` and the typed schema.
struct DefaultRulesRoundTripTests {
  @Test
  func bundledJSONDecodesThroughAgentDetectionRules() throws {
    let data = Data(DefaultRules.json.utf8)
    let decoded = try JSONDecoder().decode(AgentDetectionRules.self, from: data)
    #expect(decoded.version == AgentDetectionRules.currentVersion)
    #expect(decoded.idleThresholdSeconds == 120)
    #expect(decoded.rules.count >= 3)
    let agents = Set(decoded.rules.map(\.agent))
    #expect(agents == ["claude", "codex", "aider"])
  }

  @Test
  func bundledJSONRoundTripsLosslessly() throws {
    let data = Data(DefaultRules.json.utf8)
    let first = try JSONDecoder().decode(AgentDetectionRules.self, from: data)
    let encoded = try JSONEncoder().encode(first)
    let second = try JSONDecoder().decode(AgentDetectionRules.self, from: encoded)
    #expect(first == second)
  }

  @Test
  func everyRuleCarriesRequiredPaneOutputMatchFields() throws {
    let data = Data(DefaultRules.json.utf8)
    let rules = try JSONDecoder().decode(AgentDetectionRules.self, from: data)
    for rule in rules.rules {
      // Every default rule targets .paneOutputMatch — missingMatch is
      // enforced at decode, but we also check transitions are valid.
      #expect(rule.appliesWhen.hookEvent == .paneOutputMatch)
      #expect(rule.match != nil)
      #expect(AgentState.allCases.contains(rule.transitionTo))
      #expect(!rule.title.isEmpty)
    }
  }

  @Test
  func everyRuleTemplateIsAcceptedByRenderer() throws {
    // TemplateRenderer's init validates every {path} + filter against
    // `TemplateField.validPaths(for: rule.appliesWhen.hookEvent)`. If
    // any bundled template uses an unknown field, init throws.
    let data = Data(DefaultRules.json.utf8)
    let rules = try JSONDecoder().decode(AgentDetectionRules.self, from: data)
    _ = try TemplateRenderer(rules: rules)
  }
}
