import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct InboxStoreTests {
  // MARK: - Round-trip

  @Test
  func saveAndLoadPreservesNotifications() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))
    store.append(Self.makeNotification(agent: "claude"))
    store.append(Self.makeNotification(agent: "codex"))
    try store.saveNow()

    let fresh = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))
    let loaded = try fresh.load()
    #expect(loaded.notifications.count == 2)
    #expect(loaded.notifications.map(\.agent) == ["codex", "claude"])
  }

  @Test
  func loadOfMissingFileReturnsEmpty() throws {
    let url = Self.temporaryURL()
    let store = InboxStore(fileURL: url)
    let loaded = try store.load()
    #expect(loaded == .empty)
    #expect(store.unreadCount == 0)
  }

  // MARK: - Version gate

  @Test
  func unknownVersionIsBackedUpAndReturnsEmpty() throws {
    let tempDir = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let url = tempDir.appendingPathComponent("notifications.json")
    try Data(#"{"version": 99, "notifications": []}"#.utf8).write(to: url)

    let store = InboxStore(fileURL: url)
    let loaded = try store.load()
    #expect(loaded == .empty)

    let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(contents.contains(where: { $0.hasPrefix("notifications.json.broken-") }))
    #expect(contents.contains("notifications.json") == false)
  }

  // MARK: - 7-day sweep

  @Test
  func sweepRemovesDismissalsOlderThanSevenDays() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let eightDays: TimeInterval = 8 * 24 * 60 * 60
    let twoDays: TimeInterval = 2 * 24 * 60 * 60

    let staleDismiss = Self.makeNotification(dismissedAt: now.addingTimeInterval(-eightDays))
    let freshDismiss = Self.makeNotification(dismissedAt: now.addingTimeInterval(-twoDays))
    let live = Self.makeNotification()

    let seed = NotificationInbox(notifications: [staleDismiss, freshDismiss, live])
    try AtomicFileStore.write(seed, to: url)

    let store = InboxStore(fileURL: url)
    let loaded = try store.load(now: now)

    #expect(loaded.notifications.count == 2)
    #expect(loaded.notifications.contains(where: { $0.id == freshDismiss.id }))
    #expect(loaded.notifications.contains(where: { $0.id == live.id }))
    #expect(loaded.notifications.contains(where: { $0.id == staleDismiss.id }) == false)
  }

  // MARK: - 500-row cap

  @Test
  func appendEnforcesFiveHundredRowCap() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url)
    for index in 0..<600 {
      store.append(Self.makeNotification(body: "n\(index)"))
    }
    #expect(store.inbox.notifications.count == 500)
    // Newest-first: the last appended (body "n599") lives at index 0; the oldest
    // surviving entry is body "n100" (first 100 were trimmed).
    #expect(store.inbox.notifications.first?.body == "n599")
    #expect(store.inbox.notifications.last?.body == "n100")
  }

  // MARK: - Debounce coalescing

  @Test
  func debouncedSavesCoalesceRapidAppends() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(50))
    for _ in 0..<20 {
      store.append(Self.makeNotification())
    }
    // Before the debounce window elapses, the file has not been written.
    #expect(FileManager.default.fileExists(atPath: url.path) == false)

    // After the window, exactly one write has occurred, and the file contains all 20 entries.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(FileManager.default.fileExists(atPath: url.path) == true)
    let loaded = try AtomicFileStore.read(NotificationInbox.self, at: url)
    #expect(loaded?.notifications.count == 20)
  }

  @Test
  func saveNowFlushesSynchronouslyAndCancelsPendingTask() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .seconds(10))
    store.append(Self.makeNotification())
    // Debounced save is still pending (10s); saveNow must flush now.
    try store.saveNow()
    let loaded = try AtomicFileStore.read(NotificationInbox.self, at: url)
    #expect(loaded?.notifications.count == 1)
  }

  // MARK: - Mark read / dismiss / clearAll

  @Test
  func markReadReducesUnreadCount() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url)
    let first = Self.makeNotification()
    let second = Self.makeNotification()
    store.append(first)
    store.append(second)
    #expect(store.unreadCount == 2)

    store.markRead([first.id])
    #expect(store.unreadCount == 1)
    #expect(store.inbox.notifications.contains(where: { $0.id == first.id && $0.readAt != nil }))
  }

  @Test
  func dismissReducesUnreadCount() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url)
    let only = Self.makeNotification()
    store.append(only)
    #expect(store.unreadCount == 1)

    store.dismiss([only.id])
    #expect(store.unreadCount == 0)
  }

  @Test
  func clearAllDismissesEveryEntry() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url)
    for _ in 0..<5 {
      store.append(Self.makeNotification())
    }
    #expect(store.unreadCount == 5)

    store.clearAll()
    #expect(store.unreadCount == 0)
    #expect(store.inbox.notifications.allSatisfy { $0.dismissedAt != nil })
  }

  @Test
  func clearAllDismissesReadButUndismissedEntries() async throws {
    // Regression for the guard-semantics bug: `clearAll` previously skipped
    // the save path when every entry was already read (isUnread == false) but
    // still needed dismissedAt populated.
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(10))
    let a = Self.makeNotification()
    let b = Self.makeNotification()
    store.append(a)
    store.append(b)
    store.markRead([a.id, b.id])
    #expect(store.unreadCount == 0)
    // Both are read but not dismissed; dismissedAt fields are still nil.
    #expect(store.inbox.notifications.allSatisfy { $0.dismissedAt == nil })

    store.clearAll()
    #expect(store.inbox.notifications.allSatisfy { $0.dismissedAt != nil })
    // Save must have been scheduled — wait for the debounce window and verify.
    try await Task.sleep(nanoseconds: 200_000_000)
    let loaded = try AtomicFileStore.read(NotificationInbox.self, at: url)
    #expect(loaded?.notifications.allSatisfy { $0.dismissedAt != nil } == true)
  }

  // MARK: - Unread publisher

  @Test
  func unreadPublisherEmitsOnEveryMutation() async throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = InboxStore(fileURL: url)
    var iterator = store.unreadPublisher.makeAsyncIterator()

    store.append(Self.makeNotification())
    let first = await iterator.next()
    #expect(first == 1)

    store.append(Self.makeNotification())
    let second = await iterator.next()
    #expect(second == 2)
  }

  // MARK: - Worktree-scoped mutations (T0 M5)

  @Test
  func markReadForWorktreeOnlyMarksScopedNotifications() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))

    let panelA = Panel(workingDirectory: "/a")
    let panelB = Panel(workingDirectory: "/b")
    let worktreeA = Worktree(
      name: "a", path: "/a",
      tabs: [Tab(splitTree: SplitTree(leaf: panelA.id), panels: [panelA])]
    )
    let worktreeB = Worktree(
      name: "b", path: "/b",
      tabs: [Tab(splitTree: SplitTree(leaf: panelB.id), panels: [panelB])]
    )
    let project = Project(
      name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktreeA, worktreeB]
    )
    let catalog = Catalog(spaces: [Space(name: "s", projects: [project])])

    store.append(Self.makeNotification(panelID: panelA.id))
    store.append(Self.makeNotification(panelID: panelA.id))
    store.append(Self.makeNotification(panelID: panelB.id))
    #expect(store.unreadCount == 3)

    store.markRead(forWorktree: worktreeA.id, in: catalog)
    #expect(store.unreadCount == 1)
    #expect(store.inbox.unreadCount(forWorktree: worktreeA.id, in: catalog) == 0)
    #expect(store.inbox.unreadCount(forWorktree: worktreeB.id, in: catalog) == 1)
  }

  @Test
  func markReadForWorktreeIsIdempotent() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))

    let panel = Panel(workingDirectory: "/a")
    let worktree = Worktree(
      name: "a", path: "/a",
      tabs: [Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])]
    )
    let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
    let catalog = Catalog(spaces: [Space(name: "s", projects: [project])])

    store.append(Self.makeNotification(panelID: panel.id))
    store.markRead(forWorktree: worktree.id, in: catalog)
    let firstRead = store.inbox.notifications.first?.readAt
    store.markRead(forWorktree: worktree.id, in: catalog)
    #expect(store.inbox.notifications.first?.readAt == firstRead)
  }

  @Test
  func markReadForUnknownWorktreeIsSilentNoOp() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url)
    store.append(Self.makeNotification())
    #expect(store.unreadCount == 1)
    store.markRead(forWorktree: WorktreeID(), in: Catalog())
    #expect(store.unreadCount == 1)
  }

  @Test
  func dismissAllDelegatesToClearAll() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))
    store.append(Self.makeNotification())
    store.dismissAll()
    let notification = try #require(store.inbox.notifications.first)
    #expect(notification.isUnread == false)
    #expect(notification.dismissedAt != nil)
  }

  // MARK: - Helpers

  private static func makeNotification(
    agent: String = "claude",
    body: String = "b",
    dismissedAt: Date? = nil,
    panelID: PanelID = PanelID()
  ) -> AgentNotification {
    AgentNotification(
      panelID: panelID,
      agent: agent,
      kind: .completed,
      title: "t",
      body: body,
      createdAt: Date(timeIntervalSince1970: 0),
      readAt: nil,
      dismissedAt: dismissedAt
    )
  }

  private static func temporaryDirectory() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-notif-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private static func temporaryURL() -> URL {
    temporaryDirectory().appendingPathComponent("notifications.json")
  }
}
