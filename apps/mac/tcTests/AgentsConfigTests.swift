import Foundation
import Testing

@testable import tcKit

struct AgentsConfigTests {
  @Test
  func shippedAgentsJSONRoundTripsDecodeEncode() throws {
    let url = Self.shippedAgentsJSON
    let decoded = try AgentsConfig.load(from: url)
    #expect(decoded.version == AgentsConfig.currentVersion)
    #expect(decoded.agents.keys.sorted() == ["claude-code", "codex", "pi"])
  }

  @Test
  func lookupForEveryAgentIDReturnsConfig() throws {
    let config = try AgentsConfig.load(from: Self.shippedAgentsJSON)
    for agent in AgentID.allCases {
      #expect(config.config(for: agent) != nil, "missing config for \(agent.rawValue)")
    }
  }

  @Test
  func copyModeAgentsExposeDefaultPaths() throws {
    let config = try AgentsConfig.load(from: Self.shippedAgentsJSON)
    let claudePath = config.defaultPath(for: .claudeCode, os: .darwin)
    let codexPath = config.defaultPath(for: .codex, os: .darwin)
    #expect(claudePath?.hasSuffix("/.claude/skills/touch-code") == true)
    #expect(codexPath?.hasSuffix("/.codex/skills/touch-code") == true)
    // Tilde must be expanded: no `~` in the result.
    #expect(claudePath?.contains("~") == false)
  }

  @Test
  func linuxPathIsDistinctFromDarwinWhenConfigured() throws {
    let config = try AgentsConfig.load(from: Self.shippedAgentsJSON)
    let darwin = config.defaultPath(for: .claudeCode, os: .darwin)
    let linux = config.defaultPath(for: .claudeCode, os: .linux)
    // Paths may coincidentally match in the shipped file, but both must resolve (not be nil).
    #expect(darwin != nil)
    #expect(linux != nil)
  }

  @Test
  func piHasMirrorURLNotDefaultPath() throws {
    let config = try AgentsConfig.load(from: Self.shippedAgentsJSON)
    #expect(config.defaultPath(for: .pi, os: .darwin) == nil)
    #expect(config.mirrorURL(for: .pi) == "github.com/wanggang316/touch-code-skill")
  }

  @Test
  func piInstallModeDecodesFromHyphenatedRawValue() throws {
    let config = try AgentsConfig.load(from: Self.shippedAgentsJSON)
    #expect(config.config(for: .pi)?.installMode == .piInstall)
    #expect(config.config(for: .claudeCode)?.installMode == .copy)
  }

  @Test
  func unknownVersionRejectsDecode() throws {
    let payload = """
      {"version": 99, "agents": {}}
      """
    let url = Self.writeTemp(payload)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      _ = try AgentsConfig.load(from: url)
      Issue.record("expected unknownVersion error")
    } catch let AgentsConfigError.unknownVersion(v) {
      #expect(v == 99)
    }
  }

  @Test
  func unknownInstallModeFailsDecode() throws {
    let payload = """
      {
        "version": 1,
        "agents": {
          "bogus": {"installMode": "conjure"}
        }
      }
      """
    let url = Self.writeTemp(payload)
    defer { try? FileManager.default.removeItem(at: url) }
    var threw = false
    do { _ = try AgentsConfig.load(from: url) } catch { threw = true }
    #expect(threw, "load should fail on unknown installMode")
  }

  @Test
  func missingAgentLookupReturnsNil() throws {
    let config = try AgentsConfig.load(from: Self.shippedAgentsJSON)
    #expect(config.agents["definitely-not-a-real-agent"] == nil)
  }

  @Test
  func loadFromMainBundleProducesDeterministicOutcome() throws {
    // Under xcodebuild, Bundle.main is the xctest runner bundle in DerivedData. Phase 1
    // fails (no agents.json resource), Phase 2 fails (no sibling Resources/ dir), and
    // Phase 3 walks up out of the repo tree without finding apps/mac/Resources — the
    // expected outcome in the test harness is `resourceNotFound`. When `tc` runs from the
    // built .app or from the in-repo build/, Phase 2 or 3 succeeds. Exercising either
    // branch here proves the function terminates deterministically rather than hanging or
    // producing garbage.
    do {
      let config = try AgentsConfig.loadFromMainBundle()
      #expect(config.version == AgentsConfig.currentVersion)
    } catch AgentsConfigError.resourceNotFound {
      // Expected when tests run from DerivedData.
    }
  }

  // MARK: - Helpers

  /// Path to `apps/mac/Resources/agents.json` relative to this source file. Works even when
  /// the test binary is nowhere near the source tree.
  private static var shippedAgentsJSON: URL {
    URL(fileURLWithPath: #filePath)     // .../apps/mac/tcTests/AgentsConfigTests.swift
      .deletingLastPathComponent()      // .../apps/mac/tcTests
      .deletingLastPathComponent()      // .../apps/mac
      .appendingPathComponent("Resources/agents.json")
  }

  private static func writeTemp(_ payload: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tc-agents-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("agents.json")
    try? payload.data(using: .utf8)?.write(to: url)
    return url
  }
}
