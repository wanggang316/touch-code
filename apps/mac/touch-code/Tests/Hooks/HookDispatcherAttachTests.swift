import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore

@MainActor
struct HookDispatcherAttachTests {
  @Test
  func attachFiresMappedEnvelopesIntoExecutor() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, panelID, _, _, _, _) = EventMapperTests.fixture()
    let sub = HookSubscription(event: .panelReady, command: "echo")
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    dispatcher.attach(to: stream, catalog: { catalog })

    continuation.yield(.panelReady(panelID))
    // Give the attach Task a scheduling window.
    try await Task.sleep(for: .milliseconds(50))

    #expect(executor.invocations.count == 1)
    #expect(executor.invocations.first?.envelope.event == .panelReady)
    #expect(executor.invocations.first?.envelope.panel?.id == panelID)

    continuation.finish()
    dispatcher.stop()
  }

  @Test
  func hierarchyMutatedDoesNotFire() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, _, _, _, _, _) = EventMapperTests.fixture()
    dispatcher.setConfig(
      HookConfig(subscriptions: [HookSubscription(event: .panelReady, command: "echo")])
    )

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    dispatcher.attach(to: stream, catalog: { catalog })

    continuation.yield(.hierarchyMutated(.catalog))
    try await Task.sleep(for: .milliseconds(50))
    #expect(executor.invocations.isEmpty)

    continuation.finish()
    dispatcher.stop()
  }

  @Test
  func stopCancelsAttachedStream() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let (catalog, panelID, _, _, _, _) = EventMapperTests.fixture()
    dispatcher.setConfig(
      HookConfig(subscriptions: [HookSubscription(event: .panelReady, command: "echo")])
    )

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    dispatcher.attach(to: stream, catalog: { catalog })

    dispatcher.stop()
    try await Task.sleep(for: .milliseconds(20))
    continuation.yield(.panelReady(panelID))
    try await Task.sleep(for: .milliseconds(50))

    // After stop() the attach Task is cancelled; no new events dispatch.
    #expect(executor.invocations.isEmpty)
    continuation.finish()
  }

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
