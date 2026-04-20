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
    let sub = HookSubscription(event: .panelReady, command: "echo ready")
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
}
