import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore
@testable import TouchCodeIPC

/// Self-test for the harness. Uses `system.hello` + `system.ping` against
/// a minimal router.
@MainActor
struct InMemoryIPCServerTests {
  @Test
  func handshakeThenPingRoundTrips() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try Self.sendHello(server)
    let hello = try await server.awaitResponse()
    #expect(hello.id == "hello-1")
    #expect(hello.error == nil)

    try server.send(IPC.Request(id: "ping-1", method: .systemPing))
    let ping = try await server.awaitResponse()
    #expect(ping.id == "ping-1")
    #expect(ping.error == nil)
  }

  @Test
  func nonHelloFirstFrameIsRejected() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try server.send(IPC.Request(id: "bad-1", method: .systemPing))
    let response = try await server.awaitResponse()
    if case .versionMismatch = response.error {
      // expected
    } else {
      Issue.record("expected versionMismatch, got \(String(describing: response.error))")
    }
  }

  // MARK: - Harness helpers

  static func makeHarness(
    dispatcher: HookDispatcher? = nil
  ) -> InMemoryIPCServer {
    let (store, dispatcher) = Self.makeDispatcher(existing: dispatcher)
    let hookHandlers = HookHandlers(dispatcher: dispatcher, store: store)
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.3.0", appBundle: "0.3.0+test")
    )
    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers
    )
    let server = InMemoryIPCServer(router: router)
    server.start()
    return server
  }

  static func makeDispatcher(
    existing: HookDispatcher?
  ) -> (HookConfigStore, HookDispatcher) {
    let url = Self.tempURL()
    let store = HookConfigStore(fileURL: url)
    if let existing {
      return (store, existing)
    }
    let dispatcher = HookDispatcher(
      config: .empty,
      store: store,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )
    return (store, dispatcher)
  }

  static func tempURL() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-ipc-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("hooks.json")
  }

  static func sendHello(_ server: InMemoryIPCServer, id: String = "hello-1") throws {
    let hello = try JSONValue.encoded(HelloRequest(
      clientVersion: "0.3.0", clientBinary: "tc"
    ))
    try server.send(IPC.Request(id: id, method: .systemHello, params: hello))
  }
}
