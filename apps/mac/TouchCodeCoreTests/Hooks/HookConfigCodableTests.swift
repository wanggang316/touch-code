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
  func unknownScopeKindDroppedWhenItAppearsFirst() throws {
    // Cursor-advance regression guard: a bad entry in the first slot must not leak into
    // the next decode. Foundation's UnkeyedDecodingContainer does not advance on throw,
    // so the fail-soft loop consumes the slot via AnyCodableShim before retrying.
    let badID = UUID().uuidString
    let goodID = UUID().uuidString
    let payload = Data(#"""
      {
        "version": 2,
        "subscriptions": [
          {
            "id": "\#(badID)",
            "event": "pane.ready",
            "command": "boom",
            "scope": { "kind": "futureKind", "value": "abc" }
          },
          {
            "id": "\#(goodID)",
            "event": "pane.ready",
            "command": "noop",
            "scope": { "kind": "anyPane" }
          }
        ]
      }
      """#.utf8)
    let config = try JSONDecoder().decode(HookConfig.self, from: payload)
    #expect(config.subscriptions.count == 1)
    #expect(config.subscriptions.first?.id.uuidString == goodID)
  }

  @Test
  func twoConsecutiveUnknownScopeKindsAreBothDropped() throws {
    // Double-bad-entry guard: two UnknownScopeKind throws in a row must each consume
    // their slot before the next good entry is reached.
    let bad1 = UUID().uuidString
    let bad2 = UUID().uuidString
    let goodID = UUID().uuidString
    let payload = Data(#"""
      {
        "version": 2,
        "subscriptions": [
          {
            "id": "\#(bad1)",
            "event": "pane.ready",
            "command": "b1",
            "scope": { "kind": "futureKindA", "value": "abc" }
          },
          {
            "id": "\#(bad2)",
            "event": "pane.ready",
            "command": "b2",
            "scope": { "kind": "futureKindB" }
          },
          {
            "id": "\#(goodID)",
            "event": "pane.ready",
            "command": "noop",
            "scope": { "kind": "anyPane" }
          }
        ]
      }
      """#.utf8)
    let config = try JSONDecoder().decode(HookConfig.self, from: payload)
    #expect(config.subscriptions.count == 1)
    #expect(config.subscriptions.first?.id.uuidString == goodID)
  }

  @Test
  func malformedSubscriptionsContainerPropagatesError() {
    // `subscriptions` present but not an array should NOT silently default to [] —
    // that would clear every hook on the next save. The decoder propagates the typed
    // error so the outer loader can back the file aside.
    let payload = Data(#"""
      {
        "version": 2,
        "subscriptions": { "not": "an array" }
      }
      """#.utf8)
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(HookConfig.self, from: payload)
    }
  }

  @Test
  func missingSubscriptionsKeyDefaultsToEmpty() throws {
    // A key that is absent (not present-but-wrong-type) is the intentional legitimate
    // shape for a brand-new hooks.json. Defaults to empty; decode succeeds.
    let payload = Data(#"{"version": 2}"#.utf8)
    let config = try JSONDecoder().decode(HookConfig.self, from: payload)
    #expect(config.subscriptions.isEmpty)
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
