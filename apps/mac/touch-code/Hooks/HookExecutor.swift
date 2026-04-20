import Foundation
import TouchCodeCore

/// Outcome of running one hook handler. Populated whether the handler
/// exited cleanly, timed out, or failed to spawn.
public struct HookExecutionResult: Equatable, Sendable {
  public let exitCode: Int32
  public let stdout: Data
  public let stderr: Data
  public let duration: TimeInterval
  public let timedOut: Bool
  public let actions: [HookAction]

  public init(
    exitCode: Int32,
    stdout: Data = Data(),
    stderr: Data = Data(),
    duration: TimeInterval = 0,
    timedOut: Bool = false,
    actions: [HookAction] = []
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.duration = duration
    self.timedOut = timedOut
    self.actions = actions
  }

  public static let zero = HookExecutionResult(exitCode: 0)
}

/// Protocol seam for `HookDispatcher`. The real `ProcessHookExecutor`
/// spawns `/bin/sh -c <command>` with the envelope on stdin; tests swap in
/// `FakeHookExecutor` to record invocations without touching `Process`.
public protocol HookExecutor: Sendable {
  func run(subscription: HookSubscription, envelope: HookEnvelope) async -> HookExecutionResult
}

/// Test double: records `(subscription, envelope)` invocations and returns
/// a caller-supplied result. Thread-safe via a `Mutex`-like queue.
public final class FakeHookExecutor: HookExecutor, @unchecked Sendable {
  public struct Invocation: Sendable {
    public let subscription: HookSubscription
    public let envelope: HookEnvelope
  }

  private let lock = NSLock()
  private var _invocations: [Invocation] = []
  private var resultProvider: (@Sendable (HookSubscription, HookEnvelope) -> HookExecutionResult)?

  public init(result: HookExecutionResult = .zero) {
    self.resultProvider = { _, _ in result }
  }

  public init(resultProvider: @escaping @Sendable (HookSubscription, HookEnvelope) -> HookExecutionResult) {
    self.resultProvider = resultProvider
  }

  public var invocations: [Invocation] {
    lock.lock(); defer { lock.unlock() }
    return _invocations
  }

  public func run(
    subscription: HookSubscription,
    envelope: HookEnvelope
  ) async -> HookExecutionResult {
    await Task.yield()
    appendInvocation(Invocation(subscription: subscription, envelope: envelope))
    return resultProvider?(subscription, envelope) ?? .zero
  }

  private func appendInvocation(_ invocation: Invocation) {
    lock.lock()
    _invocations.append(invocation)
    lock.unlock()
  }
}
