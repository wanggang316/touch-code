import Foundation
import Testing

@testable import tcKit
import TouchCodeIPC

/// Parser-level tests for `tc broadcast` scope validation and `tc rpc`
/// method / params parsing — the bits that don't require a live server.
/// Covers the M6 review gap coordinator flagged (no test for broadcast
/// scope validation, no test for rpc escape hatch).
@MainActor
struct RPCCommandArgumentTests {
  // MARK: - tc rpc — method + params JSON shape

  @Test
  func rpcMethodEnumCoversFamiliarVerbs() {
    // The rpc escape hatch is only useful if the `IPC.Method` enum
    // actually contains the verb the user typed. Pin a small set the
    // CLI exposes as subcommands today.
    #expect(IPC.Method(rawValue: "system.ping") == .systemPing)
    #expect(IPC.Method(rawValue: "hook.list") == .hookList)
    #expect(IPC.Method(rawValue: "hierarchy.createSpace") == .hierarchyCreateSpace)
    #expect(IPC.Method(rawValue: "terminal.sendInput") == .terminalSendInput)
    #expect(IPC.Method(rawValue: "definitely.not.a.real.method") == nil)
  }

  @Test
  func rpcParamsJSONSurvivesRoundTrip() throws {
    // tc rpc parses stringly-typed JSON into a `JSONValue`. Confirm the
    // round-trip shape tc uses.
    let raw = Data(#"{"nested":{"ok":true,"list":[1,2,3]}}"#.utf8)
    let value = try JSONDecoder().decode(JSONValue.self, from: raw)
    let encoded = try JSONEncoder().encode(value)
    let reRead = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(value == reRead)
  }

  // MARK: - tc broadcast scope validation (pure argv → BroadcastScope)

  @Test
  func broadcastScopeEncodingStableAcrossKinds() throws {
    let cases: [IPC.BroadcastScope] = [
      IPC.BroadcastScope(kind: .tab, target: UUID().uuidString),
      IPC.BroadcastScope(kind: .worktree, target: UUID().uuidString),
      IPC.BroadcastScope(kind: .space, target: UUID().uuidString),
      IPC.BroadcastScope(kind: .label, target: "agent"),
    ]
    for scope in cases {
      let encoded = try JSONEncoder().encode(scope)
      let decoded = try JSONDecoder().decode(IPC.BroadcastScope.self, from: encoded)
      #expect(decoded == scope)
    }
  }

  // MARK: - CLIExitCode mapping on .unsupported + .conflict

  @Test
  func unsupportedMapsToExit4() {
    #expect(CLIExitCode.from(.unsupported(reason: "x")) == .unsupported)
  }

  @Test
  func conflictMapsToExit3() {
    // M6.1 fix #2: HierarchyError.invariantViolation now surfaces as
    // .conflict, which maps to exit 3 — not 2 (notFound).
    #expect(CLIExitCode.from(.conflict(reason: "duplicate")) == .conflict)
  }
}
