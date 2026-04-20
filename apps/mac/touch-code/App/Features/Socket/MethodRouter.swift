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
  private let hierarchyHandlers: HierarchyHandlers?
  private let terminalHandlers: TerminalHandlers?
  private let openHandlers: SystemOpenHandlers?
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "router")

  init(
    hookHandlers: HookHandlers,
    systemHandlers: SystemHandlers,
    hierarchyHandlers: HierarchyHandlers? = nil,
    terminalHandlers: TerminalHandlers? = nil,
    openHandlers: SystemOpenHandlers? = nil
  ) {
    self.hookHandlers = hookHandlers
    self.systemHandlers = systemHandlers
    self.hierarchyHandlers = hierarchyHandlers
    self.terminalHandlers = terminalHandlers
    self.openHandlers = openHandlers
  }

  /// Route one decoded request to the appropriate handler. The handshake
  /// verb `system.hello` is routed here alongside other `system.*` calls.
  /// Unknown methods produce `RouterOutcome.failed(.unknownMethod)`.
  public func route(_ request: IPC.Request) async -> RouterOutcome {
    logger.debug("route \(request.method.rawValue, privacy: .public) id=\(request.id, privacy: .public)")
    if let outcome = await routeSystem(request) { return outcome }
    if let outcome = await routeHook(request) { return outcome }
    if let outcome = await routeHierarchy(request) { return outcome }
    if let outcome = await routeTerminal(request) { return outcome }
    if let outcome = await routeOpen(request) { return outcome }
    return notWired(request.method)
  }

  private func routeOpen(_ request: IPC.Request) async -> RouterOutcome? {
    guard let o = openHandlers else { return nil }
    switch request.method {
    case .systemOpenInEditor: return await o.openInEditor(request.params)
    case .systemOpenPath:     return await o.openPath(request.params)
    default: return nil
    }
  }

  private func routeHierarchy(_ request: IPC.Request) async -> RouterOutcome? {
    guard let h = hierarchyHandlers else { return nil }
    switch request.method {
    case .hierarchyListSpaces:     return await h.listSpaces(request.params)
    case .hierarchyDescribeSpace:  return await h.describeSpace(request.params)
    case .hierarchyResolveAlias:   return await h.resolveAlias(request.params)
    case .hierarchyCreateSpace:    return await h.createSpace(request.params)
    case .hierarchyActivateSpace:  return await h.activateSpace(request.params)
    case .hierarchyActivateWorktree: return await h.activateWorktree(request.params)
    case .hierarchyActivateTab:    return await h.activateTab(request.params)
    case .hierarchyAddProject:     return await h.addProject(request.params)
    case .hierarchyCreateWorktree: return await h.createWorktree(request.params)
    case .hierarchyCreateTab:      return await h.createTab(request.params)
    case .hierarchyOpenPanel:      return await h.openPanel(request.params)
    case .hierarchySetPanelLabels: return await h.setPanelLabels(request.params)
    default: return nil
    }
  }

  private func routeTerminal(_ request: IPC.Request) async -> RouterOutcome? {
    guard let t = terminalHandlers else { return nil }
    switch request.method {
    case .terminalSendInput:      return await t.sendInput(request.params)
    case .terminalBroadcastInput: return await t.broadcastInput(request.params)
    default: return nil
    }
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
