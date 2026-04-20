import Foundation
import TouchCodeCore

/// Per-panel output coalescer. Batches `append(bytes:)` calls and emits a
/// single `.panelOutput` event at most once per `flushInterval`, or when the
/// buffer reaches `maxBufferSize`. Caller must arrange a flush before drop
/// (or rely on the `deinit` fallback, which hops to the main queue).
@MainActor
final class PendingOutputBuffer {
  let panelID: PanelID
  let flushInterval: Duration
  let maxBufferSize: Int

  private var buffer = Data()
  private var flushTask: Task<Void, Never>?
  private let emit: @MainActor @Sendable (PanelID, Data) -> Void

  init(
    panelID: PanelID,
    flushInterval: Duration = .milliseconds(16),
    maxBufferSize: Int = 16 * 1024,
    emit: @escaping @MainActor @Sendable (PanelID, Data) -> Void
  ) {
    self.panelID = panelID
    self.flushInterval = flushInterval
    self.maxBufferSize = maxBufferSize
    self.emit = emit
  }

  isolated deinit {
    flushTask?.cancel()
    if !buffer.isEmpty {
      drain()
    }
  }

  func append(_ bytes: Data) {
    buffer.append(bytes)

    if buffer.count >= maxBufferSize {
      flush()
      return
    }

    if flushTask == nil {
      armFlushTimer()
    }
  }

  /// Public: cancel pending timer and drain any buffered bytes immediately.
  func flush() {
    flushTask?.cancel()
    flushTask = nil
    drain()
  }

  private func drain() {
    guard !buffer.isEmpty else { return }
    let payload = buffer
    buffer = Data()
    emit(panelID, payload)
  }

  private func armFlushTimer() {
    flushTask = Task { [weak self] in
      guard let interval = self?.flushInterval else { return }
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }
}
