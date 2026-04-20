import Foundation
import Testing

@testable import TouchCodeCore

struct HookSubscriptionCodableTests {
  @Test
  func minimalSubscriptionRoundTrip() throws {
    let sub = HookSubscription(event: .panelReady, command: "echo ready")
    let data = try JSONEncoder().encode(sub)
    let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
    #expect(decoded == sub)
  }

  @Test
  func fullSubscriptionRoundTrip() throws {
    let sub = HookSubscription(
      event: .panelOutputMatch,
      command: "~/bin/notify-agent-done",
      matchPattern: "(?i)\\bready\\b",
      matchFlags: [.caseInsensitive, .multiline],
      scope: .panelLabel("agent"),
      timeoutSeconds: 2.5,
      mode: .awaitActions,
      cwd: "$WORKTREE",
      env: ["AGENT_NAME": "claude"],
      allowRawOutput: true,
      allowRawInput: false,
      idleThresholdSeconds: 120,
      disabled: false
    )
    let data = try JSONEncoder().encode(sub)
    let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
    #expect(decoded == sub)
  }

  @Test
  func everyScopeVariantRoundTrips() throws {
    let variants: [HookSubscription.Scope] = [
      .anyPanel,
      .panelID(PanelID()),
      .panelLabel("agent"),
      .tabID(TabID()),
      .tabLabel("tests"),
      .worktreeID(WorktreeID()),
      .worktreePathGlob("**/exp/*"),
    ]
    for scope in variants {
      let sub = HookSubscription(event: .panelReady, command: "noop", scope: scope)
      let data = try JSONEncoder().encode(sub)
      let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
      #expect(decoded.scope == scope, "scope mismatch for \(scope)")
    }
  }

  @Test
  func regexFlagsEncodeAsRawBitmask() throws {
    let flags: HookSubscription.RegexFlags = [.caseInsensitive, .dotAll]
    let data = try JSONEncoder().encode(flags)
    let decoded = try JSONDecoder().decode(HookSubscription.RegexFlags.self, from: data)
    #expect(decoded == flags)
  }

  @Test
  func idRoundTripsPreservedVerbatim() throws {
    // M1.x follow-up: explicit guard against future CodingKeys regression.
    let fixedID = UUID(uuidString: "DEADBEEF-DEAD-4BED-8EED-DEADBEEFDEAD")!
    let sub = HookSubscription(id: fixedID, event: .panelReady, command: "echo")
    let data = try JSONEncoder().encode(sub)
    let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
    #expect(decoded.id == fixedID)
    // Belt-and-suspenders: ensure the JSON literally contains the UUID.
    let s = String(bytes: data, encoding: .utf8) ?? ""
    #expect(s.uppercased().contains(fixedID.uuidString.uppercased()))
  }
}
