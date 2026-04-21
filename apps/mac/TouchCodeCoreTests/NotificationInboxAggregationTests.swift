import Foundation
import Testing

@testable import TouchCodeCore

struct NotificationInboxAggregationTests {
  // Fixture: 1 Space, 2 Projects; Project P1 has 2 Worktrees (W1a, W1b),
  // Project P2 has 1 Worktree (W2). Each Worktree has one Panel.
  // Inbox: unread on W1a, read on W1a, unread on W1b, none on W2.
  struct Fixture {
    let catalog: Catalog
    let spaceID: SpaceID
    let projectP1: ProjectID
    let projectP2: ProjectID
    let worktreeW1a: WorktreeID
    let worktreeW1b: WorktreeID
    let worktreeW2: WorktreeID
    let panelP1a: PanelID
    let panelP1b: PanelID
    let panelP2: PanelID
    let inbox: NotificationInbox

    init() {
      let pA = Panel(workingDirectory: "/a")
      let pB = Panel(workingDirectory: "/b")
      let pC = Panel(workingDirectory: "/c")

      let w1a = Worktree(
        name: "main", path: "/repo1",
        tabs: [Tab(splitTree: SplitTree(leaf: pA.id), panels: [pA])]
      )
      let w1b = Worktree(
        name: "feature", path: "/repo1-feat",
        tabs: [Tab(splitTree: SplitTree(leaf: pB.id), panels: [pB])]
      )
      let w2 = Worktree(
        name: "main", path: "/repo2",
        tabs: [Tab(splitTree: SplitTree(leaf: pC.id), panels: [pC])]
      )

      let p1 = Project(name: "repo1", rootPath: "/repo1", gitRoot: "/repo1", worktrees: [w1a, w1b])
      let p2 = Project(name: "repo2", rootPath: "/repo2", gitRoot: "/repo2", worktrees: [w2])
      let s = Space(name: "work", projects: [p1, p2])
      self.catalog = Catalog(spaces: [s], selectedSpaceID: s.id)

      self.spaceID = s.id
      self.projectP1 = p1.id
      self.projectP2 = p2.id
      self.worktreeW1a = w1a.id
      self.worktreeW1b = w1b.id
      self.worktreeW2 = w2.id
      self.panelP1a = pA.id
      self.panelP1b = pB.id
      self.panelP2 = pC.id

      let older = Date(timeIntervalSince1970: 1_000)
      let newer = Date(timeIntervalSince1970: 2_000)
      let notifications: [AgentNotification] = [
        // Two on W1a: one read, one unread. Read one is OLDER so time-
        // descending order puts the unread one first.
        AgentNotification(
          panelID: pA.id, agent: "claude", kind: .completed,
          title: "done", body: "", createdAt: older, readAt: older
        ),
        AgentNotification(
          panelID: pA.id, agent: "claude", kind: .blockedOnInput,
          title: "input?", body: "", createdAt: newer
        ),
        // One on W1b: unread.
        AgentNotification(
          panelID: pB.id, agent: "codex", kind: .completed,
          title: "ok", body: "", createdAt: newer
        ),
      ]
      self.inbox = NotificationInbox(notifications: notifications)
    }
  }

  @Test
  func unreadCountForWorktreeExcludesReadNotifications() {
    let f = Fixture()
    #expect(f.inbox.unreadCount(forWorktree: f.worktreeW1a, in: f.catalog) == 1)
    #expect(f.inbox.unreadCount(forWorktree: f.worktreeW1b, in: f.catalog) == 1)
    #expect(f.inbox.unreadCount(forWorktree: f.worktreeW2, in: f.catalog) == 0)
  }

  @Test
  func hasUnreadForProjectAggregatesAcrossWorktrees() {
    let f = Fixture()
    #expect(f.inbox.hasUnread(forProject: f.projectP1, in: f.catalog) == true)
    #expect(f.inbox.hasUnread(forProject: f.projectP2, in: f.catalog) == false)
  }

  @Test
  func hasUnreadForSpaceAggregatesAcrossProjects() {
    let f = Fixture()
    #expect(f.inbox.hasUnread(forSpace: f.spaceID, in: f.catalog) == true)

    // Drain unread: mark both unread entries read and assert false.
    var drained = f.inbox
    let now = Date()
    for index in drained.notifications.indices where drained.notifications[index].readAt == nil {
      drained.notifications[index].readAt = now
    }
    #expect(drained.hasUnread(forSpace: f.spaceID, in: f.catalog) == false)
  }

  @Test
  func notificationsForWorktreeOrderedNewestFirstIncludesRead() {
    let f = Fixture()
    let w1a = f.inbox.notifications(forWorktree: f.worktreeW1a, in: f.catalog)
    #expect(w1a.count == 2)
    // Newer (unread) first, older (read) second.
    #expect(w1a.first?.isUnread == true)
    #expect(w1a.last?.isUnread == false)
  }

  @Test
  func dismissedNotificationsAreNotUnreadButStillListed() {
    let f = Fixture()
    var inbox = f.inbox
    // Dismiss the unread W1a entry; aggregate unread should drop to zero.
    for index in inbox.notifications.indices where inbox.notifications[index].panelID == f.panelP1a
      && inbox.notifications[index].readAt == nil {
      inbox.notifications[index].dismissedAt = Date()
    }
    #expect(inbox.unreadCount(forWorktree: f.worktreeW1a, in: f.catalog) == 0)
    // But `notifications(forWorktree:)` still lists both entries — it does
    // not filter by dismissed state.
    #expect(inbox.notifications(forWorktree: f.worktreeW1a, in: f.catalog).count == 2)
  }

  @Test
  func notificationsForWorktreeIsDeterministicOnCreatedAtTies() {
    let f = Fixture()
    let sameTime = Date(timeIntervalSince1970: 3_000)
    let idA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let idB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let idC = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    let tieA = AgentNotification(
      id: idB, panelID: f.panelP1a, agent: "x", kind: .completed,
      title: "b", body: "", createdAt: sameTime
    )
    let tieB = AgentNotification(
      id: idA, panelID: f.panelP1a, agent: "x", kind: .completed,
      title: "a", body: "", createdAt: sameTime
    )
    let tieC = AgentNotification(
      id: idC, panelID: f.panelP1a, agent: "x", kind: .completed,
      title: "c", body: "", createdAt: sameTime
    )
    // Insert in one order...
    let inbox1 = NotificationInbox(notifications: [tieA, tieB, tieC])
    // ...and again in a different order.
    let inbox2 = NotificationInbox(notifications: [tieC, tieA, tieB])

    let sorted1 = inbox1.notifications(forWorktree: f.worktreeW1a, in: f.catalog)
    let sorted2 = inbox2.notifications(forWorktree: f.worktreeW1a, in: f.catalog)
    #expect(sorted1.map(\.id) == sorted2.map(\.id))
    // Tie-break goes by ascending uuidString, so idA (…0001) comes before
    // idB (…0002) before idC (…0003).
    #expect(sorted1.map(\.id) == [idA, idB, idC])
  }

  @Test
  func aggregationIgnoresPanelsNotInCatalog() {
    let f = Fixture()
    let stray = AgentNotification(
      panelID: PanelID(), agent: "ghost", kind: .idle,
      title: "", body: "", createdAt: Date()
    )
    var inbox = f.inbox
    inbox.notifications.insert(stray, at: 0)
    #expect(inbox.unreadCount(forWorktree: f.worktreeW1a, in: f.catalog) == 1)
    #expect(inbox.unreadCount(forWorktree: f.worktreeW1b, in: f.catalog) == 1)
    #expect(inbox.hasUnread(forSpace: f.spaceID, in: f.catalog) == true)
  }
}
