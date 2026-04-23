import Foundation
import TouchCodeCore

/// Per-pane output coalescer. Batches `append(bytes:)` calls and emits a
/// single `.paneOutput` event at most once per `flushInterval`, or when the
/// buffer reaches `maxBufferSize`. Callers should invoke `flush()` (or
/// `TerminalEngine.disposeOutputBuffer`) before releasing the buffer —
/// the `isolated deinit` drain is a MainActor-synchronous safety net, but
/// if the owning engine has already called `finishEventStream` the emit is
/// a no-op and the bytes silently fall on the floor.
@MainActor
final class PendingOutputBuffer {
  let paneID: PaneID
  let flushInterval: Duration
  let maxBufferSize: Int

  private var buffer = Data()
  private var flushTask: Task<Void, Never>?
  private let emit: @MainActor @Sendable (PaneID, Data) -> Void

  init(
    paneID: PaneID,
    flushInterval: Duration = .milliseconds(16),
    maxBufferSize: Int = 16 * 1024,
    emit: @escaping @MainActor @Sendable (PaneID, Data) -> Void
  ) {
    self.paneID = paneID
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
    emit(paneID, payload)
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
