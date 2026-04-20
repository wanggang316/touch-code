import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore

@MainActor
struct HookDispatcherTests {
  @Test
  func fireInvokesMatchingSubscription() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let sub = HookSubscription(event: .panelReady, command: "echo ready")
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    await dispatcher.fire(Self.makePanelReadyEnvelope())

    #expect(executor.invocations.count == 1)
    #expect(executor.invocations.first?.subscription.id == sub.id)
  }

  @Test
  func disabledSubscriptionIsNotFired() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    var sub = HookSubscription(event: .panelReady, command: "echo")
    sub.disabled = true
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    await dispatcher.fire(Self.makePanelReadyEnvelope())
    #expect(executor.invocations.isEmpty)
  }

  @Test
  func eventMismatchIsNotFired() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let sub = HookSubscription(event: .panelCrashed, command: "echo")
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    await dispatcher.fire(Self.makePanelReadyEnvelope()) // event = panelReady
    #expect(executor.invocations.isEmpty)
  }

  @Test
  func sentinelPrefixRoutesToInternalSubscriber() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = Self.makeDispatcher(executor: executor)

    let subscriber = RecordingInternalSubscriber()
    try dispatcher.register(
      subscriber: subscriber,
      for: "\(touchCodeInternalPrefix)notifications:"
    )

    let sub = HookSubscription(
      event: .panelReady,
      command: "\(touchCodeInternalPrefix)notifications:abc"
    )
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    await dispatcher.fire(Self.makePanelReadyEnvelope())

    // Executor must not have been called — sentinel short-circuit wins.
    #expect(executor.invocations.isEmpty)
    #expect(subscriber.receivedEnvelopes.count == 1)
  }

  @Test
  func registerRejectsNonReservedPrefix() throws {
    let dispatcher = Self.makeDispatcher()
    let subscriber = RecordingInternalSubscriber()
    #expect(throws: HookConfigError.self) {
      try dispatcher.register(subscriber: subscriber, for: "user:foo")
    }
  }

  @Test
  func internalEventStreamReceivesFiredEnvelope() async throws {
    let dispatcher = Self.makeDispatcher()
    let stream = dispatcher.internalEventStream()

    dispatcher.setConfig(HookConfig(subscriptions: []))
    await dispatcher.fire(Self.makePanelReadyEnvelope())

    // Consume one envelope from the stream with a short timeout.
    let envelopes = await withTaskGroup(of: [HookEnvelope].self) { group in
      group.addTask {
        var out: [HookEnvelope] = []
        for await env in stream {
          out.append(env)
          if out.count >= 1 { break }
        }
        return out
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(1))
        return []
      }
      let first = await group.next() ?? []
      group.cancelAll()
      return first
    }
    #expect(envelopes.count == 1)
  }

  @Test
  func fireRecordsEntryInRecentRing() async throws {
    let executor = FakeHookExecutor(result: HookExecutionResult(exitCode: 0))
    let dispatcher = Self.makeDispatcher(executor: executor)

    let sub = HookSubscription(event: .panelReady, command: "echo")
    dispatcher.setConfig(HookConfig(subscriptions: [sub]))

    await dispatcher.fire(Self.makePanelReadyEnvelope())

    let recent = dispatcher.recentFires.recent()
    #expect(recent.count == 1)
    #expect(recent.first?.subscriptionID == sub.id)
  }

  // MARK: - Helpers

  static func makeDispatcher(
    executor: HookExecutor = FakeHookExecutor(),
    actionDispatcher: HookActionDispatcher = RecordingHookActionDispatcher()
  ) -> HookDispatcher {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-hook-dispatcher-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("hooks.json")
    let store = HookConfigStore(fileURL: url)
    return HookDispatcher(
      config: .empty,
      store: store,
      executor: executor,
      actionDispatcher: actionDispatcher
    )
  }

  static func makePanelReadyEnvelope() -> HookEnvelope {
    HookEnvelope(
      event: .panelReady,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: .init(id: TabID()),
      panel: .init(id: PanelID(), workingDirectory: "/"),
      data: .panelReady(pid: nil, shell: "/bin/sh")
    )
  }
}

final class RecordingInternalSubscriber: InternalHookSubscriber, @unchecked Sendable {
  private let lock = NSLock()
  private var _envelopes: [HookEnvelope] = []

  init() {}

  var receivedEnvelopes: [HookEnvelope] {
    lock.lock(); defer { lock.unlock() }
    return _envelopes
  }

  func handle(envelope: HookEnvelope) async {
    await Task.yield()
    appendEnvelope(envelope)
  }

  private func appendEnvelope(_ envelope: HookEnvelope) {
    lock.lock()
    _envelopes.append(envelope)
    lock.unlock()
  }
}
