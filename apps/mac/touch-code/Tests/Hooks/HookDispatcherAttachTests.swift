import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct HookDispatcherAttachTests {
  @Test
  func attachFiresMappedEnvelopesIntoExecutor() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, paneID, _, _, _) = EventMapperTests.fixture()
    let sub = HookSubscription(event: .paneReady, command: "echo")
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    dispatcher.attach(to: stream, catalog: { catalog })

    continuation.yield(.paneReady(paneID))
    // Observe the fire deterministically rather than racing a sleep:
    // poll-until-condition with a 2 s hard deadline. A scheduler blip
    // on CI pushes this above a fixed 50 ms naked sleep; 2 s is
    // enough to absorb that without flipping the test's intent.
    try await Self.waitUntil(
      { executor.invocations.count == 1 },
      timeout: .seconds(2)
    )

    #expect(executor.invocations.first?.envelope.event == .paneReady)
    #expect(executor.invocations.first?.envelope.pane?.id == paneID)

    continuation.finish()
    dispatcher.stop()
  }

  @Test
  func hierarchyMutatedDoesNotFire() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, paneID, _, _, _) = EventMapperTests.fixture()
    dispatcher.setConfig(
      HookConfig(subscriptions: [HookSubscription(event: .paneReady, command: "echo")])
    )

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    dispatcher.attach(to: stream, catalog: { catalog })

    // Sandwich: yield hierarchyMutated (should NOT fire), then a
    // paneReady we can positively observe. Once the later event has
    // round-tripped through the attach Task, we know the earlier one
    // was processed and skipped — no dead-reckoning sleeps.
    continuation.yield(.hierarchyMutated(.catalog))
    continuation.yield(.paneReady(paneID))
    try await Self.waitUntil(
      { executor.invocations.count >= 1 },
      timeout: .seconds(2)
    )
    #expect(executor.invocations.count == 1, "hierarchyMutated must not fire")
    #expect(executor.invocations.first?.envelope.event == .paneReady)

    continuation.finish()
    dispatcher.stop()
  }

  @Test
  func stopCancelsAttachedStream() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, paneID, _, _, _) = EventMapperTests.fixture()
    dispatcher.setConfig(
      HookConfig(subscriptions: [HookSubscription(event: .paneReady, command: "echo")])
    )

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    dispatcher.attach(to: stream, catalog: { catalog })

    dispatcher.stop()
    // Give the cancellation a scheduling window; there's no positive
    // signal for "task was cancelled", so we must sample absence. A
    // 250 ms window is long enough that the cancellation has
    // propagated (ms-level in practice) without making the test slow.
    try await Task.sleep(for: .milliseconds(100))
    continuation.yield(.paneReady(paneID))
    try await Task.sleep(for: .milliseconds(250))

    // After stop() the attach Task is cancelled; no new events dispatch.
    #expect(executor.invocations.isEmpty)
    continuation.finish()
  }

  @Test
  func paneOutputMatchFiresWhenPatternHits() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, paneID, _, _, _) = EventMapperTests.fixture()
    let sub = HookSubscription(
      event: .paneOutputMatch,
      command: "echo match",
      matchPattern: #"ERROR: \w+"#
    )
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    let outputEnvelope = HookEnvelope(
      event: .paneOutput,
      pane: HookEnvelope.PaneRef(
        id: paneID,
        workingDirectory: "/tmp/wt",
        initialCommand: nil,
        labels: []
      ),
      data: .paneOutput(output: Data("noise\nERROR: boom\ntrailing".utf8), outputBytes: 30)
    )
    _ = catalog
    await dispatcher.fire(outputEnvelope)

    #expect(executor.invocations.count == 1)
    let invocation = executor.invocations[0]
    #expect(invocation.subscription.id == sub.id)
    #expect(invocation.envelope.event == .paneOutputMatch)
    if case .paneOutputMatch(let matched, _, _, _) = invocation.envelope.data {
      #expect(matched == "ERROR: boom")
    } else {
      Issue.record("expected .paneOutputMatch data")
    }
  }

  @Test
  func paneOutputMatchSkipsWhenPatternMisses() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let sub = HookSubscription(
      event: .paneOutputMatch,
      command: "echo match",
      matchPattern: #"ERROR: \w+"#
    )
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    let outputEnvelope = HookEnvelope(
      event: .paneOutput,
      pane: HookEnvelope.PaneRef(
        id: PaneID(),
        workingDirectory: "/tmp/wt",
        initialCommand: nil,
        labels: []
      ),
      data: .paneOutput(output: Data("all clear".utf8), outputBytes: 9)
    )
    await dispatcher.fire(outputEnvelope)
    #expect(executor.invocations.isEmpty)
  }

  /// Poll `condition` until it returns true or the timeout elapses.
  /// Throws if the condition never holds — gives a clear failure mode
  /// instead of a silent false negative from an under-long sleep.
  static func waitUntil(
    _ condition: () -> Bool,
    timeout: Duration,
    pollInterval: Duration = .milliseconds(5),
    file: StaticString = #file,
    line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
      if ContinuousClock.now >= deadline {
        throw WaitTimeout()
      }
      try await Task.sleep(for: pollInterval)
    }
  }

  struct WaitTimeout: Error {}

  // MARK: - Harness

  static func makeDispatcher(executor: FakeHookExecutor) -> HookDispatcher {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hook-attach-\(UUID().uuidString).json")
    let store = HookConfigStore(fileURL: url)
    return HookDispatcher(
      config: .empty,
      store: store,
      executor: executor,
      actionDispatcher: RecordingHookActionDispatcher()
    )
  }
}
