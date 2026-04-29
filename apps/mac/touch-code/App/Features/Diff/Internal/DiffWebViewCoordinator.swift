import Foundation
import WebKit

/// Bridges `WKScriptMessageHandler` callbacks into the SwiftUI host's
/// `onEvent` closure. Holds the closure by value (it's swapped in
/// `updateNSView` whenever the SwiftUI parent re-evaluates) but does NOT
/// retain the `WKWebView` — the representable owns the view, the
/// coordinator only owns wiring.
final class DiffWebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  static let bridgeName = "yitongBridge"

  /// Queue of pending host→web messages while the renderer initialises.
  /// Messages enqueued before the `ready` event are flushed in arrival
  /// order; afterwards the queue stays empty and we forward immediately.
  private var pendingScripts: [String] = []
  private var ready = false

  var onEvent: ((DiffEvent) -> Void)?

  /// Set by the representable on view creation. Weak-ish via closure
  /// capture to avoid the coordinator strong-retaining the WebView.
  var evaluator: ((String) -> Void)?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let raw = message.body as? String else { return }
    let event: DiffEvent
    do {
      event = try DiffWebViewBridge.decodeEvent(raw)
    } catch {
      event = .didFail(code: "decode_failed", message: String(describing: error))
    }
    if case .didFinishInitialLoad = event {
      ready = true
      flushPending()
    }
    DispatchQueue.main.async { [onEvent] in
      onEvent?(event)
    }
  }

  /// Either evaluates immediately (renderer is ready) or queues until the
  /// `ready` event arrives. Drops stale `renderDocument` messages: only
  /// the most recent one is meaningful, so we replace earlier queued
  /// renders to avoid flashing through outdated states.
  func dispatch(script: String, kind: SendKind) {
    if ready {
      evaluator?(script)
      return
    }
    if kind == .render {
      pendingScripts.removeAll(where: { $0.contains("\"renderDocument\"") })
    }
    pendingScripts.append(script)
  }

  private func flushPending() {
    let queued = pendingScripts
    pendingScripts.removeAll(keepingCapacity: false)
    for script in queued { evaluator?(script) }
  }

  enum SendKind {
    case render
    case options
  }
}
