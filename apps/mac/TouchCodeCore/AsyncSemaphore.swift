import Foundation

/// Counting async semaphore with FIFO wait order.
///
/// Used by `HookDispatcher` + `ProcessHookExecutor` to cap concurrent
/// hook handler spawns at `HookDispatcher.defaultMaxConcurrency`. A single
/// instance is shared between the two sites so backpressure applies
/// regardless of whether the dispatcher holds the permit across
/// `executor.run` (blocking handlers) or the detached spawn re-acquires
/// after `fireAndForget` handoff.
public actor AsyncSemaphore {
  private let permits: Int
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(permits: Int) {
    precondition(permits > 0, "AsyncSemaphore needs a positive permit count")
    self.permits = permits
    self.available = permits
  }

  public func acquire() async {
    if available > 0 {
      available -= 1
      return
    }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      waiters.append(cont)
    }
  }

  public func release() {
    if waiters.isEmpty {
      available = min(available + 1, permits)
      return
    }
    let waiter = waiters.removeFirst()
    waiter.resume()
  }

  /// Snapshot of outstanding waiters — test-visible.
  public var waiterCount: Int { waiters.count }

  /// Snapshot of available permits — test-visible.
  public var availablePermits: Int { available }
}
