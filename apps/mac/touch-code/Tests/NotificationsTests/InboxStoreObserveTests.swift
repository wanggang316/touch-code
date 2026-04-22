import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Covers the multi-subscriber `InboxStore.observeInbox()` primitive
/// added in M5. Each call returns a fresh `AsyncStream<NotificationInbox>`
/// with replay-current semantics on subscribe and fan-out on every
/// mutation. Regressions here silently break the InboxClient → reducer
/// integration, so the primitive gets its own focused coverage.
@MainActor
struct InboxStoreObserveTests {
  @Test
  func subscribeAfterMutationReceivesCurrentSnapshot() async throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, debounce: .seconds(3600))

    // Seed two entries BEFORE anyone subscribes.
    store.append(Self.makeNotification(agent: "claude"))
    store.append(Self.makeNotification(agent: "codex"))

    // Fresh subscribe — must see the current (2-entry) inbox as the
    // very first yielded value, without any further mutation.
    var iterator = store.observeInbox().makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.notifications.count == 2)
  }

  @Test
  func twoSubscribersEachReceiveMutation() async throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, debounce: .seconds(3600))

    var iterator1 = store.observeInbox().makeAsyncIterator()
    var iterator2 = store.observeInbox().makeAsyncIterator()

    // Drain the initial replay — each subscriber sees the empty inbox.
    let replay1 = await iterator1.next()
    let replay2 = await iterator2.next()
    #expect(replay1?.notifications.isEmpty == true)
    #expect(replay2?.notifications.isEmpty == true)

    store.append(Self.makeNotification(agent: "claude"))

    // Both subscribers must observe the mutation independently.
    let update1 = await iterator1.next()
    let update2 = await iterator2.next()
    #expect(update1?.notifications.count == 1)
    #expect(update2?.notifications.count == 1)
  }

  @Test
  func terminatedSubscriberIsCleanedUp() async throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, debounce: .seconds(3600))

    // Subscribe, then end the stream. The subscription's onTermination
    // closure hops back to MainActor and removes the continuation from
    // the subscribers dictionary. We then confirm the registry drained
    // back to zero entries by adding a fresh subscriber and verifying
    // it still gets the replayed state + the next mutation — i.e. the
    // store is still in a healthy fan-out state after churn.
    do {
      var iterator = store.observeInbox().makeAsyncIterator()
      _ = await iterator.next()  // consume replay
    }
    // Yield to let onTermination run on the MainActor.
    try await Task.sleep(nanoseconds: 20_000_000)

    var fresh = store.observeInbox().makeAsyncIterator()
    let replay = await fresh.next()
    #expect(replay?.notifications.isEmpty == true)

    store.append(Self.makeNotification(agent: "aider"))
    let update = await fresh.next()
    #expect(update?.notifications.count == 1)
  }

  // MARK: - Helpers

  private static func makeNotification(agent: String) -> AgentNotification {
    AgentNotification(
      panelID: PanelID(),
      agent: agent,
      kind: .completed,
      title: "t",
      body: "b",
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  private static func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(component: "inbox-observe-\(UUID().uuidString).json")
  }
}
