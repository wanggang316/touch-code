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
  /// Each entry pairs the script payload with its `SendKind` so we can
  /// dedupe by kind without parsing the JSON. Entries enqueued before the
  /// `ready` event are flushed in arrival order; afterwards the queue
  /// stays empty and we forward immediately.
  private var pendingScripts: [(script: String, kind: SendKind)] = []
  private var ready = false

  /// Last script we actually evaluated for each `SendKind`. Acts as a
  /// post-ready dedupe: SwiftUI's `updateNSView` runs on every parent
  /// re-evaluation (geometry, environment, sibling state) and re-encodes
  /// the same payload; without this cache we'd re-trigger Shiki tokenising
  /// on every appearance toggle or window resize. Reset by
  /// `dismantleNSView` so a fresh WebView mount starts clean.
  private var lastOptionsScript: String?
  private var lastRenderScript: String?

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
  /// `ready` event arrives. Two layers of dedupe:
  ///
  /// 1. Pre-ready (queue): a fresh `.render` evicts any earlier `.render`
  ///    so we don't flash through outdated documents on first paint.
  /// 2. Post-ready (sent-cache): an identical script for the same kind is
  ///    suppressed entirely — guards against `updateNSView` storms from
  ///    SwiftUI re-evaluations re-shipping a byte-identical payload.
  func dispatch(script: String, kind: SendKind) {
    if ready {
      switch kind {
      case .options where lastOptionsScript == script: return
      case .render where lastRenderScript == script: return
      default: break
      }
      evaluator?(script)
      switch kind {
      case .options: lastOptionsScript = script
      case .render: lastRenderScript = script
      }
      return
    }
    if kind == .render {
      pendingScripts.removeAll(where: { $0.kind == .render })
    }
    pendingScripts.append((script, kind))
  }

  /// Test-only hook: flip the `ready` flag and flush any queued scripts
  /// without rigging up a `WKScriptMessage` round-trip. Production code
  /// only ever transitions to `ready` via the inbound `ready` event in
  /// `userContentController(_:didReceive:)`.
  #if DEBUG
    func markReadyForTesting() {
      ready = true
      flushPending()
    }
  #endif

  /// Drops the post-ready send-cache. Called from `DiffWebView.dismantleNSView`
  /// so a fresh WebView mount starts with no remembered scripts.
  func resetSendCache() {
    lastOptionsScript = nil
    lastRenderScript = nil
    pendingScripts.removeAll(keepingCapacity: false)
    ready = false
  }

  private func flushPending() {
    let queued = pendingScripts
    pendingScripts.removeAll(keepingCapacity: false)
    for entry in queued {
      evaluator?(entry.script)
      switch entry.kind {
      case .options: lastOptionsScript = entry.script
      case .render: lastRenderScript = entry.script
      }
    }
  }

  enum SendKind {
    case render
    case options
  }
}
