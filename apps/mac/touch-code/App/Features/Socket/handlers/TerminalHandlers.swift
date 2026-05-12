import Foundation
import TouchCodeCore
import TouchCodeIPC
import os

/// Handlers for `terminal.*` — send input into a pane, broadcast across
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
    func sendInput(paneID: PaneID, text: String) -> Bool
    func fanOut(scope: IPC.BroadcastScope, text: String, catalog: Catalog) -> Int
    func readText(paneID: PaneID, extent: ReadExtent) -> String?
    func resetPane(paneID: PaneID) -> Bool
  }

  public enum ReadExtent: String, Codable, Sendable {
    case viewport
    case screen
    case selection
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
    public let paneID: PaneID
    public let text: String
  }
  public func sendInput(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.sendInput requires the app with panes live"))
    }
    let req: SendInputParams
    do {
      req = try params.decoded(as: SendInputParams.self)
    } catch {
      return .failed(.invalidParams(message: "sendInput requires {paneID, text}", path: nil))
    }
    let ok = sink.sendInput(paneID: req.paneID, text: req.text)
    if !ok {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
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
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.broadcastInput requires the app with panes live"))
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

  public struct ReadTextParams: Codable, Sendable {
    public let paneID: PaneID
    public let extent: ReadExtent?
  }
  public struct ReadTextResult: Codable, Sendable {
    public let text: String
  }
  public func readText(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.readText requires the app with panes live"))
    }
    let req: ReadTextParams
    do {
      req = try params.decoded(as: ReadTextParams.self)
    } catch {
      return .failed(.invalidParams(message: "readText requires {paneID}", path: nil))
    }
    guard let text = sink.readText(paneID: req.paneID, extent: req.extent ?? .viewport) else {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    do {
      return .unary(try JSONValue.encoded(ReadTextResult(text: text)))
    } catch {
      return .failed(.internal("encode readText result: \(error)"))
    }
  }

  public struct ResetPaneParams: Codable, Sendable {
    public let paneID: PaneID
  }
  public func resetPane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let sink else {
      return .failed(
        .unsupported(reason: "no GhosttyRuntime bound — terminal.resetPane requires the app with panes live"))
    }
    let req: ResetPaneParams
    do {
      req = try params.decoded(as: ResetPaneParams.self)
    } catch {
      return .failed(.invalidParams(message: "resetPane requires {paneID}", path: nil))
    }
    let ok = sink.resetPane(paneID: req.paneID)
    if !ok {
      return .failed(.notFound(kind: "pane", id: req.paneID.description))
    }
    return .unary(.object(["reset": .bool(true)]))
  }
}
