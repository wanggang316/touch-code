import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

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
    let settings = NotificationSettingsStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString + ".json"),
      clock: ContinuousClock(),
      debounce: .milliseconds(1)
    )
    let client = InboxClient.live(inbox: inbox, settings: settings)

    let panel = Panel(workingDirectory: "/a")
    let worktree = Worktree(
      name: "a", path: "/a",
      tabs: [Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])]
    )
    let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
    let catalog = Catalog(spaces: [Space(name: "s", projects: [project])])

    inbox.append(
      AgentNotification(
        panelID: panel.id, agent: "claude", kind: .completed,
        title: "done", body: "", createdAt: Date()
      )
    )
    #expect(inbox.unreadCount == 1)

    client.markReadForWorktree(worktree.id, catalog)
    #expect(inbox.unreadCount == 0)
    #expect(inbox.inbox.notifications.first?.readAt != nil)
  }
}
