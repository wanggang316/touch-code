import Foundation
import Testing

@testable import TouchCodeCore

struct NotificationInboxTests {
  @Test
  func emptyInboxRoundTrip() throws {
    let inbox = NotificationInbox.empty
    let data = try JSONEncoder().encode(inbox)
    let decoded = try JSONDecoder().decode(NotificationInbox.self, from: data)
    #expect(decoded == inbox)
    #expect(decoded.version == NotificationInbox.currentVersion)
  }

  @Test
  func populatedInboxRoundTrip() throws {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let first = AgentNotification(
      panelID: PanelID(),
      agent: "claude",
      kind: .completed,
      title: "Claude finished",
      body: "Worktree main · Tab agent",
      createdAt: created
    )
    let second = AgentNotification(
      panelID: PanelID(),
      agent: "codex",
      kind: .blockedOnInput,
      title: "Codex is waiting",
      body: "Approve tool call?",
      createdAt: created.addingTimeInterval(60)
    )
    let inbox = NotificationInbox(notifications: [first, second])

    let data = try JSONEncoder().encode(inbox)
    let decoded = try JSONDecoder().decode(NotificationInbox.self, from: data)

    #expect(decoded == inbox)
    #expect(decoded.notifications.count == 2)
  }

  @Test
  func decodingRejectsUnknownVersion() throws {
    let payload = Data(#"{"version": 99, "notifications": []}"#.utf8)
    #expect(throws: NotificationInbox.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder().decode(NotificationInbox.self, from: payload)
    }
  }

  @Test
  func decodingTolerantOfMissingNotificationsField() throws {
    let payload = Data(#"{"version": 1}"#.utf8)
    let inbox = try JSONDecoder().decode(NotificationInbox.self, from: payload)
    #expect(inbox.notifications.isEmpty)
  }

  @Test
  func decodedNotificationsPreserveOrder() throws {
    let ids = (0..<5).map { _ in PanelID() }
    let notifications = ids.map { panelID in
      AgentNotification(
        panelID: panelID,
        agent: "aider",
        kind: .idle,
        title: "t",
        body: "b",
        createdAt: Date(timeIntervalSince1970: 0)
      )
    }
    let inbox = NotificationInbox(notifications: notifications)
    let data = try JSONEncoder().encode(inbox)
    let decoded = try JSONDecoder().decode(NotificationInbox.self, from: data)
    #expect(decoded.notifications.map(\.panelID) == ids)
  }
}
