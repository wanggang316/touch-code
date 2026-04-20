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
    switch request.method {
    // system
    case .systemHello:
      return await systemHandlers.hello(request.params)
    case .systemPing:
      return await systemHandlers.ping(request.params)
    case .systemVersion:
      return await systemHandlers.version(request.params)
    case .systemStatus:
      return await systemHandlers.status(request.params)
    case .systemQuit:
      return await systemHandlers.quit(request.params)

    // hook
    case .hookList:
      return await hookHandlers.list(request.params)
    case .hookInstall:
      return await hookHandlers.install(request.params)
    case .hookRemove:
      return await hookHandlers.remove(request.params)
    case .hookEnable:
      return await hookHandlers.enable(request.params)
    case .hookReload:
      return await hookHandlers.reload(request.params)
    case .hookTest:
      return await hookHandlers.test(request.params)
    case .hookFire:
      return await hookHandlers.fire(request.params)
    case .hookRecent:
      return await hookHandlers.recent(request.params)
    case .hookEvents:
      return hookHandlers.events(request.params)

    // hierarchy / terminal / system.openInEditor / system.openPath — land
    // with M6 / M7. For M3 every not-yet-wired method surfaces a clean
    // `.unsupported` so the CLI exits with the right code and clients
    // can version-probe without crashing.
    default:
      return .failed(.unsupported(reason: "method \(request.method.rawValue) not wired in this build"))
    }
  }
}
