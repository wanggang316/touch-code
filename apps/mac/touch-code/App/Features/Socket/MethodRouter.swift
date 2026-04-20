import Foundation
import os
import TouchCodeCore
import TouchCodeIPC

/// Dispatch target for a streaming request. Handlers that respond with
/// `.streaming` provide a subscribe closure that the connection drains
/// frame-by-frame until either side closes.
public enum RouterOutcome: Sendable {
  case unary(JSONValue)
  case streaming(@Sendable () -> AsyncStream<JSONValue>)
  case failed(IPCError)
}

/// Protocol-level router: consumes typed requests, produces typed results.
/// The `SocketConnection` actor owns the wire encoding; the router owns
/// the method-to-handler mapping.
@MainActor
public final class MethodRouter {
  private let hookHandlers: HookHandlers
  private let systemHandlers: SystemHandlers
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "router")

  public init(hookHandlers: HookHandlers, systemHandlers: SystemHandlers) {
    self.hookHandlers = hookHandlers
    self.systemHandlers = systemHandlers
  }

  /// Route one decoded request to the appropriate handler. The handshake
  /// verb `system.hello` is routed here alongside other `system.*` calls.
  /// Unknown methods produce `RouterOutcome.failed(.unknownMethod)`.
  public func route(_ request: IPC.Request) async -> RouterOutcome {
    logger.debug("route \(request.method.rawValue, privacy: .public) id=\(request.id, privacy: .public)")
    if let outcome = await routeSystem(request) { return outcome }
    if let outcome = await routeHook(request) { return outcome }
    return notWired(request.method)
  }

  private func routeSystem(_ request: IPC.Request) async -> RouterOutcome? {
    switch request.method {
    case .systemHello:   return await systemHandlers.hello(request.params)
    case .systemPing:    return await systemHandlers.ping(request.params)
    case .systemVersion: return await systemHandlers.version(request.params)
    case .systemStatus:  return await systemHandlers.status(request.params)
    case .systemQuit:    return await systemHandlers.quit(request.params)
    // Non-system methods fall through to the next sub-router. A future
    // `system.*` case landing in this router silently reaches
    // `notWired(.unsupported)` without this branch; reviewer flagged
    // (M3.0.1 nit #1) as acceptable for now — a proper fix would split
    // `IPC.Method` into per-namespace sub-enums, tracked for M3.1.
    default: return nil
    }
  }

  private func routeHook(_ request: IPC.Request) async -> RouterOutcome? {
    switch request.method {
    case .hookList:    return await hookHandlers.list(request.params)
    case .hookInstall: return await hookHandlers.install(request.params)
    case .hookRemove:  return await hookHandlers.remove(request.params)
    case .hookEnable:  return await hookHandlers.enable(request.params)
    case .hookReload:  return await hookHandlers.reload(request.params)
    case .hookTest:    return await hookHandlers.test(request.params)
    case .hookFire:    return await hookHandlers.fire(request.params)
    case .hookRecent:  return await hookHandlers.recent(request.params)
    case .hookEvents:  return hookHandlers.events(request.params)
    // See routeSystem note.
    default: return nil
    }
  }

  private func notWired(_ method: IPC.Method) -> RouterOutcome {
    .failed(.unsupported(reason: "method \(method.rawValue) not wired in this build"))
  }
}
