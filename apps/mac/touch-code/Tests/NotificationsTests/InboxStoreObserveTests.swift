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

  // MARK: - Per-worktree unread (v2 D11 / B8)

  /// `observeUnreadByWorktree` joins the inbox against a catalog
  /// snapshot and returns one entry per worktree with unread items.
  @Test
  func observeUnreadByWorktreeEmitsPerGroup() async throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, debounce: .seconds(3600))

    // Build a catalog with two worktrees, each owning one pane.
    let paneA = Pane(workingDirectory: "/a", initialCommand: nil)
    let paneB = Pane(workingDirectory: "/b", initialCommand: nil)
    let catalog = Self.catalog(panes: [paneA, paneB])
    let worktreeIDs = catalog.projects[0].worktrees.map(\.id)
    store.setCatalogProvider { catalog }

    var iterator = store.observeUnreadByWorktree().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial == [:])

    store.append(
      AgentNotification(
        paneID: paneA.id, agent: "claude", kind: .completed, title: "t", body: "b",
        createdAt: Date()
      )
    )
    store.append(
      AgentNotification(
        paneID: paneB.id, agent: "claude", kind: .completed, title: "t", body: "b",
        createdAt: Date()
      )
    )
    store.append(
      AgentNotification(
        paneID: paneA.id, agent: "claude", kind: .completed, title: "t2", body: "b",
        createdAt: Date()
      )
    )

    // Drain — multiple appends, multiple yields.
    var latest: [WorktreeID: Int] = [:]
    for _ in 0..<3 {
      if let next = await iterator.next() {
        latest = next
      }
    }
    // 2 unread on worktree[0] (paneA), 1 unread on worktree[1] (paneB).
    #expect(latest[worktreeIDs[0]] == 2)
    #expect(latest[worktreeIDs[1]] == 1)
  }

  /// Without a catalog provider the per-worktree map is empty — keeps
  /// the store usable in catalog-free unit tests.
  @Test
  func observeUnreadByWorktreeWithoutProviderYieldsEmpty() async throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, debounce: .seconds(3600))

    var iterator = store.observeUnreadByWorktree().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial == [:])
  }

  // MARK: - Helpers

  private static func catalog(panes: [Pane]) -> Catalog {
    let worktrees = panes.map { pane in
      let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
      return Worktree(
        name: "wt", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id
      )
    }
    let project = Project(
      name: "p", rootPath: "/p", gitRoot: "/p",
      worktrees: worktrees,
      selectedWorktreeID: worktrees.first?.id
    )
    return Catalog(projects: [project])
  }

  private static func makeNotification(agent: String) -> AgentNotification {
    AgentNotification(
      paneID: PaneID(),
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
