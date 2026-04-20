import Foundation
import TouchCodeCore

/// One-to-many fan-out of `HookEnvelope` stream. Each `subscribe()` call
/// returns a fresh `AsyncStream` backed by a bounded buffer (newest-first
/// eviction). A slow subscriber that stops consuming does not stall its
/// peers — its backing buffer fills, the oldest pending envelope is dropped,
/// and the subscriber observes the gap.
///
/// Exec-plan 0003 DEC-10: peer of `hook.events` RPC for in-process
/// consumers (C6, future in-app panes).
@MainActor
public final class HookEventMulticaster {
  public static let defaultBufferPerSubscriber = 64

  private struct Subscriber {
    let id: UUID
    let continuation: AsyncStream<HookEnvelope>.Continuation
  }

  private var subscribers: [Subscriber] = []
  private let bufferPerSubscriber: Int

  public init(bufferPerSubscriber: Int = HookEventMulticaster.defaultBufferPerSubscriber) {
    self.bufferPerSubscriber = bufferPerSubscriber
  }

  /// Publish an envelope to every currently-registered subscriber. Safe to
  /// call with no subscribers (silent no-op). Buffer-full subscribers
  /// observe a dropped envelope per `bufferingNewest` semantics.
  public func publish(_ envelope: HookEnvelope) {
    for subscriber in subscribers {
      subscriber.continuation.yield(envelope)
    }
  }

  /// Register a fresh subscriber. The returned `AsyncStream` finishes when
  /// `unsubscribe(id:)` is called, when the caller discards the stream
  /// (cancellation), or when the multicaster is deinitialised.
  public func subscribe() -> (id: UUID, stream: AsyncStream<HookEnvelope>) {
    let id = UUID()
    var continuation: AsyncStream<HookEnvelope>.Continuation!
    let stream = AsyncStream<HookEnvelope>(
      bufferingPolicy: .bufferingNewest(bufferPerSubscriber)
    ) { cont in
      continuation = cont
    }
    let subscriber = Subscriber(id: id, continuation: continuation)
    continuation.onTermination = { @Sendable [weak self] _ in
      Task { @MainActor [weak self] in
        self?.unsubscribe(id: id)
      }
    }
    subscribers.append(subscriber)
    return (id, stream)
  }

  /// Unregister a subscriber by id. Idempotent.
  public func unsubscribe(id: UUID) {
    if let index = subscribers.firstIndex(where: { $0.id == id }) {
      let removed = subscribers.remove(at: index)
      removed.continuation.finish()
    }
  }

  /// Current subscriber count — exposed for tests and metrics.
  public var subscriberCount: Int { subscribers.count }
}
