import Foundation
import os
import TouchCodeCore
import TouchCodeIPC

/// Handlers for `terminal.*` — send input into a panel, broadcast across
/// a scope. Backed by an injected `TerminalInputSink` so the router can
/// bind to either the real `TerminalEngine` + `GhosttyRuntime` or a
/// headless test double (or `nil`, in which case these RPCs return
/// `.unsupported`).
@MainActor
public final class TerminalHandlers {
  /// Narrow protocol over the app's input-delivery surface. Implemented
  /// by a small adapter around `GhosttyRuntime.surface(for:).sendInput`;
  /// tests stub it.
  public protocol InputSink: AnyObject, Sendable {
    func sendInput(panelID: PanelID, text: String) -> Bool
    func fanOut(scope: IPC.BroadcastScope, text: String, catalog: Catalog) -> Int
  }

  private let sink: InputSink?
  private let catalog: @MainActor () -> Catalog
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "terminal")

  public init(
    sink: InputSink?,
    catalog: @escaping @MainActor () -> Catalog
  ) {
    self.sink = sink
    self.catalog = catalog
  }

  public struct SendInputParams: Codable, Sendable {
    public let panelID: PanelID
    public let text: String
  }
  public func sendInput(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(.unsupported(reason: "no GhosttyRuntime bound — terminal.sendInput requires the app with panels live"))
    }
    let req: SendInputParams
    do {
      req = try params.decoded(as: SendInputParams.self)
    } catch {
      return .failed(.invalidParams(message: "sendInput requires {panelID, text}", path: nil))
    }
    let ok = sink.sendInput(panelID: req.panelID, text: req.text)
    if !ok {
      return .failed(.notFound(kind: "panel", id: req.panelID.description))
    }
    return .unary(.object(["delivered": .bool(true)]))
  }

  public struct BroadcastParams: Codable, Sendable {
    public let scope: IPC.BroadcastScope
    public let text: String
  }
  public func broadcastInput(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(.unsupported(reason: "no GhosttyRuntime bound — terminal.broadcastInput requires the app with panels live"))
    }
    let req: BroadcastParams
    do {
      req = try params.decoded(as: BroadcastParams.self)
    } catch {
      return .failed(.invalidParams(message: "broadcastInput requires {scope, text}", path: nil))
    }
    let count = sink.fanOut(scope: req.scope, text: req.text, catalog: catalog())
    return .unary(.object(["delivered": .int(Int64(count))]))
  }
}
