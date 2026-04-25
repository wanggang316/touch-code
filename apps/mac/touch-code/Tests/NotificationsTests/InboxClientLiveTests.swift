import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Narrow coverage of the `InboxClient.live` bridge: confirms the new
/// `markReadForWorktree` closure forwards into `InboxStore.markRead(forWorktree:in:)`
/// under the live wiring. The store-level semantics are exercised exhaustively
/// by `InboxStoreTests`; this suite only checks the bridge.
@MainActor
struct InboxClientLiveTests {
  @Test
  func markReadForWorktreeForwardsToStore() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }

    let inbox = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))
    let settings = SettingsStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString + ".json"),
      debounceWindow: .milliseconds(1)
    )
    let client = InboxClient.live(inbox: inbox, settings: settings)

    let pane = Pane(workingDirectory: "/a")
    let worktree = Worktree(
      name: "a", path: "/a",
      tabs: [Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])]
    )
    let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
    let catalog = Catalog(spaces: [Space(name: "s", projects: [project])])

    inbox.append(
      AgentNotification(
        paneID: pane.id, agent: "claude", kind: .completed,
        title: "done", body: "", createdAt: Date()
      )
    )
    #expect(inbox.unreadCount == 1)

    client.markReadForWorktree(worktree.id, catalog)
    #expect(inbox.unreadCount == 0)
    #expect(inbox.inbox.notifications.first?.readAt != nil)
  }

  /// `markReadForPane` closure must forward into
  /// `InboxStore.markRead(forPane:)` so `tc focus` and other "focus →
  /// acknowledge" paths flow through the same source of truth.
  @Test
  func markReadForPaneForwardsToStore() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let inbox = InboxStore(fileURL: url, clock: ContinuousClock(), debounce: .milliseconds(1))
    let settings = SettingsStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString + ".json"),
      debounceWindow: .milliseconds(1)
    )
    let client = InboxClient.live(inbox: inbox, settings: settings)

    let paneA = PaneID()
    let paneB = PaneID()
    inbox.append(
      AgentNotification(
        paneID: paneA, agent: "claude", kind: .completed,
        title: "A1", body: "", createdAt: Date()
      )
    )
    inbox.append(
      AgentNotification(
        paneID: paneA, agent: "claude", kind: .completed,
        title: "A2", body: "", createdAt: Date()
      )
    )
    inbox.append(
      AgentNotification(
        paneID: paneB, agent: "claude", kind: .completed,
        title: "B1", body: "", createdAt: Date()
      )
    )
    #expect(inbox.unreadCount == 3)

    client.markReadForPane(paneA)
    #expect(inbox.unreadCount == 1)  // only paneB remains unread
  }
}
