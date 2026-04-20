import Foundation
import TouchCodeCore

/// One entry in `HookRecentRing` — a record of one hook firing. Read by
/// the `hook.recent` RPC for introspection.
public struct HookFireRecord: Equatable, Codable, Sendable {
  public let id: UUID
  public let envelope: HookEnvelope
  public let subscriptionID: UUID
  public let duration: TimeInterval
  public let exitCode: Int32
  public let actionsDispatched: Int
  public let actionsRefused: Int
  public let timedOut: Bool
  public let killed: Bool
  public let rateLimited: Bool
  public let firedAt: Date

  public init(
    id: UUID = UUID(),
    envelope: HookEnvelope,
    subscriptionID: UUID,
    duration: TimeInterval,
    exitCode: Int32,
    actionsDispatched: Int = 0,
    actionsRefused: Int = 0,
    timedOut: Bool = false,
    killed: Bool = false,
    rateLimited: Bool = false,
    firedAt: Date = Date()
  ) {
    self.id = id
    self.envelope = envelope
    self.subscriptionID = subscriptionID
    self.duration = duration
    self.exitCode = exitCode
    self.actionsDispatched = actionsDispatched
    self.actionsRefused = actionsRefused
    self.timedOut = timedOut
    self.killed = killed
    self.rateLimited = rateLimited
    self.firedAt = firedAt
  }
}

/// Bounded ring buffer of recent hook firings. Default capacity 256
/// matches the C3 design doc's introspection budget.
@MainActor
public final class HookRecentRing {
  public static let defaultCapacity = 256

  private var buffer: [HookFireRecord] = []
  private let capacity: Int

  public init(capacity: Int = HookRecentRing.defaultCapacity) {
    self.capacity = capacity
    self.buffer.reserveCapacity(capacity)
  }

  public func append(_ record: HookFireRecord) {
    buffer.append(record)
    if buffer.count > capacity {
      buffer.removeFirst(buffer.count - capacity)
    }
  }

  /// Most recent entries first. Optional `limit` caps the returned slice.
  /// Avoids materialising the whole buffer as an intermediate array when
  /// `limit` is small — reads the last `limit` entries directly and
  /// reverses them in-place.
  public func recent(limit: Int? = nil) -> [HookFireRecord] {
    if let limit, limit < buffer.count {
      return Array(buffer.suffix(limit).reversed())
    }
    return Array(buffer.reversed())
  }

  public var count: Int { buffer.count }
}
