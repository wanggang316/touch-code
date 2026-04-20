import Foundation
import os
import TouchCodeCore

/// Thin adapter translating a `HookAction` into the same in-process verb
/// the `tc` CLI would drive via RPC. M2 ships a recording stub suitable
/// for unit tests and C6 observation; the real `HierarchyManager` /
/// `TerminalEngine` wiring lands with M3 / M6 when those surfaces are
/// fully live.
///
/// Exec-plan 0003 D15: the action path must **not** re-enter the socket
/// server; it must call in-process handlers directly. `HookActionDispatcher`
/// is that boundary.
public protocol HookActionDispatcher: AnyObject, Sendable {
  func execute(_ action: HookAction, originatingFrom envelopeID: UUID) async throws
}

/// No-op dispatcher that records every `execute(_:originatingFrom:)` call.
/// Used by M2 tests and as a placeholder until M6 supplies the real one.
public final class RecordingHookActionDispatcher: HookActionDispatcher, @unchecked Sendable {
  public struct Invocation: Equatable, Sendable {
    public let action: HookAction
    public let envelopeID: UUID
  }

  private let lock = NSLock()
  private var _log: [Invocation] = []
  private let logger = Logger(subsystem: "com.touch-code.hooks", category: "actions")

  public init() {}

  public var log: [Invocation] {
    lock.lock(); defer { lock.unlock() }
    return _log
  }

  public func execute(_ action: HookAction, originatingFrom envelopeID: UUID) async throws {
    await Task.yield()
    append(Invocation(action: action, envelopeID: envelopeID))
    logger.debug("action \(action.kind, privacy: .public) queued (env \(envelopeID.uuidString, privacy: .public))")
  }

  private func append(_ invocation: Invocation) {
    lock.lock()
    _log.append(invocation)
    lock.unlock()
  }
}
