import Foundation
import os
import TouchCodeCore
import TouchCodeIPC

/// Typed JSON-RPC client. One instance per `tc` invocation (C4 D10).
///
/// On `call(_:params:timeout:)` the client opens a fresh transport, sends
/// `system.hello` pipelined with the real request (DEC-4), reads the
/// hello response (discarded unless it carries an error), then returns
/// the typed `Result`.
public actor RPCClient {
  public struct Versions: Sendable {
    public let clientVersion: String
    public let clientBinary: String
    public init(clientVersion: String, clientBinary: String = "tc") {
      self.clientVersion = clientVersion
      self.clientBinary = clientBinary
    }
  }

  public enum RPCError: Error, Equatable, Sendable {
    case ipc(IPCError)
    case timeout
    case noResponse
    case streamClosed
    case decodeFailed(String)
  }

  private let transport: Transport
  private let versions: Versions
  private var buffer = Data()
  private let inboundPump: InboundPump
  private let logger = Logger(subsystem: "com.touch-code.cli", category: "rpc")

  public init(transport: Transport, versions: Versions) {
    self.transport = transport
    self.versions = versions
    self.inboundPump = InboundPump(stream: transport.inbound)
  }

  deinit {
    transport.close()
  }

  /// Unary call. Returns the decoded `Result` or throws an `RPCError`.
  public func call<Params: Encodable, ResultType: Decodable>(
    _ method: IPC.Method,
    params: Params,
    resultType: ResultType.Type = ResultType.self,
    timeout: Duration = .seconds(10)
  ) async throws -> ResultType {
    let requestID = UUID().uuidString
    let paramsJSON = try JSONValue.encoded(params)
    let request = IPC.Request(id: requestID, method: method, params: paramsJSON)

    try await pipelinedSend(request: request)

    let start = ContinuousClock.now
    let helloResponse = try await readResponse(deadline: start.advanced(by: timeout))
    if let error = helloResponse.error {
      throw RPCError.ipc(error)
    }
    let response = try await readResponse(deadline: start.advanced(by: timeout))
    if let error = response.error {
      throw RPCError.ipc(error)
    }
    guard let result = response.result else {
      throw RPCError.noResponse
    }
    do {
      return try result.decoded(as: ResultType.self)
    } catch {
      throw RPCError.decodeFailed(String(describing: error))
    }
  }

  /// Call with no typed result payload (uses `JSONValue` so callers can
  /// introspect). Convenience wrapper.
  public func callRaw<Params: Encodable>(
    _ method: IPC.Method,
    params: Params,
    timeout: Duration = .seconds(10)
  ) async throws -> JSONValue {
    try await call(method, params: params, resultType: JSONValue.self, timeout: timeout)
  }

  // MARK: - Internals

  /// Pipeline `system.hello` + the real request in one write. Saves a
  /// round trip — DEC-4.
  private func pipelinedSend(request: IPC.Request) async throws {
    let hello = IPC.Request(
      id: "hello-\(UUID().uuidString.prefix(8))",
      method: .systemHello,
      params: try JSONValue.encoded(HelloRequest(
        clientVersion: versions.clientVersion,
        clientBinary: versions.clientBinary
      ))
    )
    let helloFrame = try Framing.encode(JSONEncoder().encode(hello))
    let realFrame = try Framing.encode(JSONEncoder().encode(request))
    try await transport.send(helloFrame + realFrame)
  }

  /// Decode the next framed response from the inbound stream, honouring
  /// the deadline. Times out via an outer race between the stream pull
  /// and a sleep.
  private func readResponse(deadline: ContinuousClock.Instant) async throws -> IPC.Response {
    while ContinuousClock.now < deadline {
      if let frame = try? Framing.decode(from: &buffer) {
        return try JSONDecoder().decode(IPC.Response.self, from: frame)
      }
      guard let chunk = try await pullNext(deadline: deadline) else {
        throw RPCError.timeout
      }
      buffer.append(chunk)
    }
    throw RPCError.timeout
  }

  private func pullNext(deadline: ContinuousClock.Instant) async throws -> Data? {
    let remaining = ContinuousClock.now.duration(to: deadline)
    if remaining <= .zero { return nil }
    return await inboundPump.next(timeout: remaining)
  }
}

/// Background iterator that feeds incoming frames onto a
/// `CheckedContinuation`-based queue. Makes `await next(timeout:)`
/// trivially cancellable and sidesteps the `sending` rules that block a
/// naive `AsyncStream.Iterator` capture inside a Task.
actor InboundPump {
  private var pending: [Data] = []
  private var waiter: CheckedContinuation<Data?, Never>?
  private var finished = false

  init(stream: AsyncStream<Data>) {
    Task { [weak self] in
      for await chunk in stream {
        await self?.deliver(chunk)
      }
      await self?.finish()
    }
  }

  func next(timeout: Duration) async -> Data? {
    if let head = pending.first {
      pending.removeFirst()
      return head
    }
    if finished { return nil }

    let waiterID = UUID()
    return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
      waiter = cont
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.timeoutWaiter(id: waiterID)
      }
      _ = waiterID
    }
  }

  private func deliver(_ chunk: Data) {
    if let w = waiter {
      waiter = nil
      w.resume(returning: chunk)
    } else {
      pending.append(chunk)
    }
  }

  private func timeoutWaiter(id _: UUID) {
    if let w = waiter {
      waiter = nil
      w.resume(returning: nil)
    }
  }

  private func finish() {
    finished = true
    if let w = waiter {
      waiter = nil
      w.resume(returning: nil)
    }
  }
}
