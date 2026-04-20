import Foundation
import TouchCodeCore

/// Per-panel output coalescer. Batches `append(bytes:)` calls and emits
/// a single `.panelOutput` event at most once per `flushInterval`, or when
/// the buffer reaches `maxBufferSize`.
@MainActor
final class PendingOutputBuffer {
  let panelID: PanelID
  let flushInterval: Duration
  let maxBufferSize: Int

  private var buffer = Data()
  private var flushTask: Task<Void, Never>?
  private let emit: (PanelID, Data) -> Void

  init(
    panelID: PanelID,
    flushInterval: Duration = .milliseconds(16),
    maxBufferSize: Int = 16 * 1024,
    emit: @escaping (PanelID, Data) -> Void
  ) {
    self.panelID = panelID
    self.flushInterval = flushInterval
    self.maxBufferSize = maxBufferSize
    self.emit = emit
  }

  func append(_ bytes: Data) {
    buffer.append(bytes)

    if buffer.count >= maxBufferSize {
      flushNow()
      return
    }

    if flushTask == nil {
      armFlushTimer()
    }
  }

  func flushNow() {
    flushTask?.cancel()
    flushTask = nil
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
      await MainActor.run {
        self?.flushNow()
      }
    }
  }
}
