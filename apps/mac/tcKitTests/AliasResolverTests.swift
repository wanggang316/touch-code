import Foundation
import Testing

@testable import tcKit
import TouchCodeCore
import TouchCodeIPC

@MainActor
struct AliasResolverTests {
  @Test
  func uuidValueIsFastPathNoRPC() async throws {
    let uuid = UUID()
    let resolved = try await AliasResolver.resolve(
      uuid.uuidString,
      kind: .panel,
      env: [:],
      client: neverCalled()
    )
    #expect(resolved == uuid)
  }

  @Test
  func currentPronounReadsEnv() async throws {
    let uuid = UUID()
    let resolved = try await AliasResolver.resolve(
      "current",
      kind: .panel,
      env: ["TOUCH_CODE_PANEL_ID": uuid.uuidString],
      client: neverCalled()
    )
    #expect(resolved == uuid)
  }

  @Test
  func dotPronounReadsEnv() async throws {
    let uuid = UUID()
    let resolved = try await AliasResolver.resolve(
      ".",
      kind: .space,
      env: ["TOUCH_CODE_SPACE_ID": uuid.uuidString],
      client: neverCalled()
    )
    #expect(resolved == uuid)
  }

  @Test
  func missingContextThrows() async throws {
    do {
      _ = try await AliasResolver.resolve(
        "current",
        kind: .worktree,
        env: [:],
        client: neverCalled()
      )
      Issue.record("expected .noContext")
    } catch AliasResolver.Error.noContext(let kind) {
      #expect(kind == .worktree)
    }
  }

  @Test
  func labelRoutesToServerAndReturnsResolvedID() async throws {
    let targetID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .hierarchyResolveAlias)
      let body = try JSONEncoder().encode(
        IPC.AliasResolveResult(kind: .panel, id: targetID)
      )
      let resultJSON = try JSONDecoder().decode(JSONValue.self, from: body)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: resultJSON),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    let resolved = try await AliasResolver.resolve(
      "@agent",
      kind: .panel,
      env: [:],
      client: client
    )
    #expect(resolved == targetID)
  }

  // Helper — the UUID and context-env paths must not need a client.
  private func neverCalled() throws -> RPCClient {
    Issue.record("RPCClient was dialed when it should not have been")
    let transport = InMemoryTransport()
    return RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
  }
}
