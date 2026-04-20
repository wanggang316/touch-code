import Foundation
import TouchCodeCore

/// Public-facing façade that composes `CatalogStore`, `HierarchyManager`, and
/// `GhosttyRuntime` behind a single event stream. Feature code (TCA clients,
/// hook runner, notifications) subscribes via `events()` and mutates state
/// through `hierarchy`. Direct access to `GhosttyRuntime` or `PanelSurface`
/// objects is intentionally not exposed.
@MainActor
final class TerminalEngine {
  let hierarchy: HierarchyManager
  let store: CatalogStore

  private let eventStream: AsyncStream<TerminalEvent>
  private let eventContinuation: AsyncStream<TerminalEvent>.Continuation
  private var outputBuffers: [PanelID: PendingOutputBuffer] = [:]

  init(store: CatalogStore, hierarchy: HierarchyManager) {
    self.store = store
    self.hierarchy = hierarchy
    // Cap the buffer so a stalled consumer can't grow memory without bound —
    // one slow subscriber with N panels can otherwise retain every batch.
    let (stream, continuation) = AsyncStream<TerminalEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    self.eventStream = stream
    self.eventContinuation = continuation
  }

  /// Returns the shared event stream. Multiple subscribers are not supported —
  /// wrap with an `AsyncChannel` or multicaster if you need fan-out.
  func events() -> AsyncStream<TerminalEvent> {
    eventStream
  }

  /// Emit an event on the shared stream. Intended for `HierarchyRuntime`
  /// adapters to signal structural transitions (`panelReady`, `panelExited`)
  /// and for hierarchy mutations to announce `tabActivated` / `worktreeActivated`.
  func emit(_ event: TerminalEvent) {
    eventContinuation.yield(event)
  }

  /// Feed bytes from a ghostty surface into the per-panel coalescer. Creates
  /// a buffer on first use. Callers should invoke `flushOutput(for:)` before
  /// tearing the surface down so no bytes are dropped.
  func appendOutput(panelID: PanelID, bytes: Data) {
    let buffer = outputBuffers[panelID] ?? makeBuffer(for: panelID)
    buffer.append(bytes)
  }

  func flushOutput(for panelID: PanelID) {
    outputBuffers[panelID]?.flush()
  }

  /// Drop the per-panel output buffer. Must be called when the surface closes,
  /// otherwise pending bytes leak and the coalescer continues emitting.
  func disposeOutputBuffer(for panelID: PanelID) {
    outputBuffers[panelID]?.flush()
    outputBuffers.removeValue(forKey: panelID)
  }

  func finishEventStream() {
    eventContinuation.finish()
  }

  private func makeBuffer(for panelID: PanelID) -> PendingOutputBuffer {
    let buffer = PendingOutputBuffer(panelID: panelID) { [weak self] id, data in
      self?.emit(.panelOutput(id, data))
    }
    outputBuffers[panelID] = buffer
    return buffer
  }
}
