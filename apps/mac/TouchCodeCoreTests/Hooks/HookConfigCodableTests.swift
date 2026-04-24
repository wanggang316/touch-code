import Foundation
import Testing

@testable import TouchCodeCore

struct HookConfigCodableTests {
  @Test
  func emptyConfigRoundTrips() throws {
    let config = HookConfig()
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(HookConfig.self, from: data)
    #expect(decoded == config)
    #expect(decoded.version == HookConfig.currentVersion)
    #expect(decoded.recursionWindowMs == HookConfig.defaultRecursionWindowMs)
  }

  @Test
  func populatedConfigRoundTrips() throws {
    let sub = HookSubscription(event: .paneReady, command: "echo ready")
    let config = HookConfig(recursionWindowMs: 500, subscriptions: [sub])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(HookConfig.self, from: data)
    #expect(decoded == config)
  }

  @Test
  func decodingRejectsUnknownVersion() throws {
    let payload = Data(#"{"version": 99}"#.utf8)
    #expect(throws: HookConfig.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder().decode(HookConfig.self, from: payload)
    }
  }

  @Test
  func decodingDefaultsRecursionWindow() throws {
    let payload = Data(#"{"version": 1}"#.utf8)
    let config = try JSONDecoder().decode(HookConfig.self, from: payload)
    #expect(config.recursionWindowMs == HookConfig.defaultRecursionWindowMs)
    #expect(config.subscriptions.isEmpty)
  }

  @Test
  func decodingAcceptsLegacyV1AndNormalisesVersion() throws {
    // v1 files are still decodable under the v2 schema; in-memory `version`
    // normalises to the current value so the next save writes v2 shape.
    let payload = Data(#"{"version": 1, "recursionWindowMs": 750}"#.utf8)
    let config = try JSONDecoder().decode(HookConfig.self, from: payload)
    #expect(config.version == HookConfig.currentVersion)
    #expect(config.recursionWindowMs == 750)
  }

  @Test
  func unknownScopeKindIsDroppedNotFatal() throws {
    // One good subscription + one with an unknown `scope.kind` that a pre-update
    // binary might encounter. The loader drops the bad entry with a warning
    // rather than failing the whole file.
    let goodID = UUID().uuidString
    let badID = UUID().uuidString
    let payload = Data(#"""
      {
        "version": 2,
        "subscriptions": [
          {
            "id": "\#(goodID)",
            "event": "pane.ready",
            "command": "noop",
            "scope": { "kind": "anyPane" }
          },
          {
            "id": "\#(badID)",
            "event": "pane.ready",
            "command": "boom",
            "scope": { "kind": "futureKind", "value": "abc" }
          }
        ]
      }
      """#.utf8)
    let config = try JSONDecoder().decode(HookConfig.self, from: payload)
    #expect(config.subscriptions.count == 1)
    #expect(config.subscriptions.first?.id.uuidString == goodID)
  }

  @Test
  func v2PayloadWithNewProjectScopeRoundTrips() throws {
    let pid = ProjectID()
    let sub = HookSubscription(
      event: .paneReady,
      command: "notify",
      scope: .projectID(pid)
    )
    let config = HookConfig(subscriptions: [sub])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(HookConfig.self, from: data)
    #expect(decoded == config)
    #expect(decoded.subscriptions.first?.scope == .projectID(pid))
  }
}
