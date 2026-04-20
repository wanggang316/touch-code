import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore
@testable import TouchCodeIPC

@MainActor
struct HookHandlersTests {
  @Test
  func installThenListRoundTrip() async throws {
    let server = InMemoryIPCServerTests.makeHarness()
    defer { server.stop() }

    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let sub = HookSubscription(event: .panelReady, command: "echo ready")
    let params = try JSONValue.encoded(HookHandlers.InstallParams(subscription: sub))
    try server.send(IPC.Request(id: "install-1", method: .hookInstall, params: params))
    let installed = try await server.awaitResponse()
    #expect(installed.error == nil)

    try server.send(IPC.Request(id: "list-1", method: .hookList))
    let listed = try await server.awaitResponse()
    #expect(listed.error == nil)
    if case .object(let obj) = listed.result,
       case .array(let subs) = obj["subscriptions"] {
      #expect(subs.count == 1)
    } else {
      Issue.record("expected { subscriptions: [...] }, got \(String(describing: listed.result))")
    }
  }

  @Test
  func installRejectsReservedPrefix() async throws {
    let server = InMemoryIPCServerTests.makeHarness()
    defer { server.stop() }

    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let bad = HookSubscription(
      event: .panelReady,
      command: "\(touchCodeInternalPrefix)notifications:x"
    )
    let params = try JSONValue.encoded(HookHandlers.InstallParams(subscription: bad))
    try server.send(IPC.Request(id: "install-reserved", method: .hookInstall, params: params))
    let response = try await server.awaitResponse()
    if case .conflict = response.error {
      // expected
    } else {
      Issue.record("expected .conflict, got \(String(describing: response.error))")
    }
  }

  @Test
  func removeUnknownIDReturnsNotFound() async throws {
    let server = InMemoryIPCServerTests.makeHarness()
    defer { server.stop() }

    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let params = try JSONValue.encoded(HookHandlers.RemoveParams(id: UUID()))
    try server.send(IPC.Request(id: "rm-1", method: .hookRemove, params: params))
    let response = try await server.awaitResponse()
    if case .notFound = response.error {
      // expected
    } else {
      Issue.record("expected .notFound, got \(String(describing: response.error))")
    }
  }

  @Test
  func enableFlipsInvertedStoredField() async throws {
    let server = InMemoryIPCServerTests.makeHarness()
    defer { server.stop() }

    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    // Install
    let sub = HookSubscription(event: .panelReady, command: "echo")
    let installParams = try JSONValue.encoded(HookHandlers.InstallParams(subscription: sub))
    try server.send(IPC.Request(id: "i", method: .hookInstall, params: installParams))
    _ = try await server.awaitResponse()

    // Disable
    let enableParams = try JSONValue.encoded(HookHandlers.EnableParams(id: sub.id, enabled: false))
    try server.send(IPC.Request(id: "e", method: .hookEnable, params: enableParams))
    let response = try await server.awaitResponse()
    #expect(response.error == nil)
  }
}
