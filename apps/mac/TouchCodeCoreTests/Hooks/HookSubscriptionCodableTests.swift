import Foundation
import Testing

@testable import TouchCodeCore

struct HookSubscriptionCodableTests {
  @Test
  func minimalSubscriptionRoundTrip() throws {
    let sub = HookSubscription(event: .paneReady, command: "echo ready")
    let data = try JSONEncoder().encode(sub)
    let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
    #expect(decoded == sub)
  }

  @Test
  func fullSubscriptionRoundTrip() throws {
    let sub = HookSubscription(
      event: .paneOutputMatch,
      command: "~/bin/notify-agent-done",
      matchPattern: "(?i)\\bready\\b",
      matchFlags: [.caseInsensitive, .multiline],
      scope: .paneLabel("agent"),
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
      .anyPane,
      .paneID(PaneID()),
      .paneLabel("agent"),
      .tabID(TabID()),
      .tabLabel("tests"),
      .worktreeID(WorktreeID()),
      .worktreePathGlob("**/exp/*"),
      .projectID(ProjectID()),
      .projectPathGlob("/Users/x/dev/**"),
    ]
    for scope in variants {
      let sub = HookSubscription(event: .paneReady, command: "noop", scope: scope)
      let data = try JSONEncoder().encode(sub)
      let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
      #expect(decoded.scope == scope, "scope mismatch for \(scope)")
    }
  }

  @Test
  func unknownScopeKindThrowsTypedError() throws {
    let pid = ProjectID().raw.uuidString
    let json = #"""
      {
        "id": "\#(UUID().uuidString)",
        "event": "pane.ready",
        "command": "noop",
        "scope": { "kind": "futureKind", "value": "\#(pid)" }
      }
      """#
    #expect(throws: HookSubscription.Scope.UnknownScopeKind.self) {
      _ = try JSONDecoder().decode(HookSubscription.self, from: Data(json.utf8))
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
    let sub = HookSubscription(id: fixedID, event: .paneReady, command: "echo")
    let data = try JSONEncoder().encode(sub)
    let decoded = try JSONDecoder().decode(HookSubscription.self, from: data)
    #expect(decoded.id == fixedID)
    // Belt-and-suspenders: ensure the JSON literally contains the UUID.
    let s = String(bytes: data, encoding: .utf8) ?? ""
    #expect(s.uppercased().contains(fixedID.uuidString.uppercased()))
  }
}
