import Foundation
import Testing
import tcKit

@testable import touch_code
@testable import TouchCodeCore
@testable import TouchCodeIPC

/// End-to-end integration tests: a real `RPCClient` (with its pipelined
/// handshake, inbound-pump actor, and typed Codable decode) driving a
/// real `MethodRouter` + real app-side handlers (`HookHandlers`,
/// `HierarchyHandlers`, `SystemHandlers`, `TerminalHandlers`) over a
/// `RouterBackedTransport`. The transport preserves the full wire stack
/// — Framing (DEC-3) + `SocketConnection`'s read-dispatch-write loop —
/// and skips only the Unix socket fd itself.
///
/// These tests assert multi-step scenarios (install → list → fire →
/// recent; create-space → activate → describe) through the same typed
/// `client.call(_:params:)` API the `tc` CLI uses in production. A
/// regression in Codable alignment between request params / response
/// payloads / CLI decoders surfaces here, not just at the individual
/// handler-unit-test level. `UnixSocketTransport`'s accept / read / fd
/// lifecycle is covered by manual validation in M8's §M8 steps and
/// remains untested at the Swift-Testing level (tracked under M8.1).
@MainActor
struct EndToEndRPCIntegrationTests {
  // MARK: - System verbs

  @Test
  func systemPingRoundtrips() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    struct PingResult: Codable { let pong: Bool }
    let result: PingResult = try await client.call(.systemPing, params: Empty())
    #expect(result.pong == true)
  }

  @Test
  func systemVersionReportsHarnessVersions() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    struct Version: Codable { let server: String; let appBundle: String }
    let version: Version = try await client.call(.systemVersion, params: Empty())
    #expect(version.server == "0.3.0")
    #expect(version.appBundle == "0.3.0+test")
  }

  // MARK: - Hook lifecycle

  @Test
  func hookInstallListFireRecentFullLifecycle() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    let sub = HookSubscription(event: .panelReady, command: "echo ready")

    // 1. install
    struct InstallParams: Codable { let subscription: HookSubscription }
    struct InstallResult: Codable { let id: String }
    let installed: InstallResult = try await client.call(
      .hookInstall,
      params: InstallParams(subscription: sub)
    )
    #expect(installed.id == sub.id.uuidString)

    // 2. list — should see our hook
    struct ListResult: Codable { let subscriptions: [HookSubscription] }
    let listed: ListResult = try await client.call(.hookList, params: Empty())
    #expect(listed.subscriptions.map(\.id).contains(sub.id))

    // 3. fire — triggers the FakeHookExecutor
    let envelope = HookEnvelope(
      event: .panelReady,
      data: .panelReady(pid: nil, shell: "bash")
    )
    struct FireParams: Codable { let envelope: HookEnvelope }
    struct FireResult: Codable { let handlersRun: Int }
    let fired: FireResult = try await client.call(
      .hookFire,
      params: FireParams(envelope: envelope)
    )
    #expect(fired.handlersRun >= 1)

    // 4. recent — the fire should appear in the ring buffer
    struct RecentParams: Codable { let limit: Int? }
    struct RecentResult: Codable { let fires: [HookFireRecord] }
    let recent: RecentResult = try await client.call(
      .hookRecent,
      params: RecentParams(limit: 5)
    )
    #expect(!recent.fires.isEmpty)
  }

  // MARK: - Hierarchy mutation + describe

  @Test
  func hierarchyCreateActivateDescribeRoundtrip() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    struct CreateParams: Codable { let name: String; let activate: Bool }
    struct IDResult: Codable { let id: SpaceID }
    let created: IDResult = try await client.call(
      .hierarchyCreateSpace,
      params: CreateParams(name: "e2e", activate: true)
    )

    struct DescribeParams: Codable { let id: SpaceID }
    let space: Space = try await client.call(
      .hierarchyDescribeSpace,
      params: DescribeParams(id: created.id)
    )
    #expect(space.id == created.id)
    #expect(space.name == "e2e")
  }

  // MARK: - Error-path contract

  @Test
  func editorOpenFallsThroughToUnsupported() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    // `editor.open` is in IPC.Method but has no handler in this plan's
    // router (C8 owns the handler). Proves the notWired fall-through
    // returns `.unsupported` so the CLI exits 4 post-merge too.
    struct Params: Codable {
      let worktreeID: WorktreeID?
      let path: String?
      let editor: String?
    }
    do {
      _ = try await client.callRaw(
        .editorOpen,
        params: Params(worktreeID: nil, path: "/tmp", editor: nil)
      )
      Issue.record("expected throw")
    } catch RPCClient.RPCError.ipc(let err) {
      if case .unsupported = err {
        // expected
      } else {
        Issue.record("expected .unsupported, got \(err)")
      }
    }
  }

  @Test
  func describeMissingSpaceSurfacesNotFound() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    struct DescribeParams: Codable { let id: SpaceID }
    do {
      _ = try await client.call(
        .hierarchyDescribeSpace,
        params: DescribeParams(id: SpaceID(raw: UUID())),
        resultType: Space.self
      )
      Issue.record("expected throw")
    } catch RPCClient.RPCError.ipc(let err) {
      if case .notFound(let kind, _) = err {
        #expect(kind == "space")
      } else {
        Issue.record("expected .notFound, got \(err)")
      }
    }
  }

  @Test
  func terminalSendWithNoSinkReturnsUnsupported() async throws {
    let (client, server) = try makeStack()
    defer { server.stop() }
    defer { Task { await client.shutdown() } }

    struct Params: Codable { let panelID: PanelID; let text: String }
    do {
      _ = try await client.callRaw(
        .terminalSendInput,
        params: Params(panelID: PanelID(raw: UUID()), text: "hello")
      )
      Issue.record("expected throw")
    } catch RPCClient.RPCError.ipc(let err) {
      if case .unsupported = err {
        // expected — this harness binds `sink: nil`, matching the
        // AppBootstrap shape until a real GhosttyRuntime is wired.
      } else {
        Issue.record("expected .unsupported, got \(err)")
      }
    }
  }

  // MARK: - Harness

  struct Empty: Codable, Sendable {}

  /// Build a full (router, client) pair connected by a
  /// `RouterBackedTransport`. The server is a real `MethodRouter` with
  /// every handler wired; the client is a real `RPCClient`.
  func makeStack() throws -> (RPCClient, RouterBackedTransport) {
    let hookConfigURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("touch-code-integ-\(UUID().uuidString).json")
    let hookStore = HookConfigStore(fileURL: hookConfigURL)
    let dispatcher = HookDispatcher(
      config: .empty,
      store: hookStore,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )
    let hookHandlers = HookHandlers(dispatcher: dispatcher, store: hookStore)
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.3.0", appBundle: "0.3.0+test")
    )

    let catalogURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("touch-code-integ-catalog-\(UUID().uuidString).json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let catalog = (try? catalogStore.load()) ?? Catalog()
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )
    let hierarchyHandlers = HierarchyHandlers(manager: hierarchy)
    let terminalHandlers = TerminalHandlers(sink: nil, catalog: { hierarchy.catalog })

    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers
    )

    let transport = RouterBackedTransport(router: router)
    transport.start()
    let client = RPCClient(
      transport: transport,
      versions: .init(clientVersion: "0.3.0", clientBinary: "tc-integration-test")
    )
    return (client, transport)
  }
}

/// A `Transport` implementation that wraps a live `MethodRouter` +
/// `SocketConnection` pair in process, skipping only the Unix-socket
/// fd. The client-facing `send` feeds raw framed request bytes into the
/// connection's inbound stream, and the connection's outbound writes
/// land in this transport's `inbound` stream. Everything in between is
/// the same code the production server runs: Framing, handshake,
/// routing, typed Codable decode.
@MainActor
public final class RouterBackedTransport: Transport, @unchecked Sendable {
  private let router: MethodRouter
  private var serverInbound: AsyncStream<Data>.Continuation?
  private var serveTask: Task<Void, Never>?

  private let clientInboundContinuation: AsyncStream<Data>.Continuation
  public let inbound: AsyncStream<Data>

  public init(router: MethodRouter) {
    self.router = router
    var cont: AsyncStream<Data>.Continuation!
    self.inbound = AsyncStream<Data> { cont = $0 }
    self.clientInboundContinuation = cont
  }

  public func start() {
    guard serveTask == nil else { return }

    var serverInboundCont: AsyncStream<Data>.Continuation!
    let serverInboundStream = AsyncStream<Data> { c in serverInboundCont = c }
    self.serverInbound = serverInboundCont

    let clientCont = self.clientInboundContinuation
    let conn = SocketConnection(
      router: router,
      reader: serverInboundStream,
      write: { data in
        clientCont.yield(data)
      },
      close: {
        clientCont.finish()
      }
    )
    serveTask = Task.detached { await conn.serve() }
  }

  public nonisolated func send(_ frame: Data) async throws {
    // Hop back to MainActor to yield into the server's inbound stream.
    await feed(frame)
  }

  private func feed(_ data: Data) {
    serverInbound?.yield(data)
  }

  public nonisolated func close() {
    Task { @MainActor [weak self] in
      self?.stopInternal()
    }
  }

  public func stop() {
    stopInternal()
  }

  private func stopInternal() {
    serverInbound?.finish()
    serverInbound = nil
    serveTask?.cancel()
    serveTask = nil
    clientInboundContinuation.finish()
  }
}
