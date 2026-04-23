import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct HookDispatcherConcurrencyTests {
  /// 20 concurrent dispatches against a sleepy fake executor with
  /// `maxConcurrency=3` must never let more than 3 `run` calls overlap.
  @Test
  func semaphoreSerializesConcurrentDispatches() async throws {
    let maxConcurrency = 3
    let tracker = ConcurrentRunTracker()
    let executor = SleepingFakeExecutor(tracker: tracker, sleepNanos: 30_000_000)  // 30 ms

    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("hook-concurrency-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = HookConfigStore(fileURL: dir.appendingPathComponent("hooks.json"))

    let dispatcher = HookDispatcher(
      config: .empty,
      store: store,
      executor: executor,
      actionDispatcher: RecordingHookActionDispatcher(),
      maxConcurrency: maxConcurrency
    )

    let sub = HookSubscription(event: .paneReady, command: "echo")
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    let envelope = HookDispatcherTests.makePaneReadyEnvelope()
    var tasks: [Task<Void, Never>] = []
    for _ in 0..<20 {
      let task = Task { await dispatcher.fire(envelope) }
      tasks.append(task)
    }
    for task in tasks { await task.value }

    #expect(tracker.peak <= maxConcurrency)
    #expect(tracker.total == 20)
  }
}

/// Thread-safe peak-concurrency tracker.
final class ConcurrentRunTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var current = 0
  private(set) var peak = 0
  private(set) var total = 0

  func enter() {
    lock.lock()
    current += 1
    total += 1
    if current > peak { peak = current }
    lock.unlock()
  }

  func leave() {
    lock.lock()
    current -= 1
    lock.unlock()
  }
}

/// Fake executor that holds the "inside `run`" window for `sleepNanos` so
/// the test can observe how many dispatches overlap.
final class SleepingFakeExecutor: HookExecutor, @unchecked Sendable {
  let tracker: ConcurrentRunTracker
  let sleepNanos: UInt64

  init(tracker: ConcurrentRunTracker, sleepNanos: UInt64) {
    self.tracker = tracker
    self.sleepNanos = sleepNanos
  }

  func run(subscription: HookSubscription, envelope: HookEnvelope) async -> HookExecutionResult {
    tracker.enter()
    defer { tracker.leave() }
    try? await Task.sleep(nanoseconds: sleepNanos)
    return .zero
  }
}
