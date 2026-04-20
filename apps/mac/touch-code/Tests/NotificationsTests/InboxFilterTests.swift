import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

struct InboxFilterTests {
  @Test
  func allReturnsEveryNonDismissedEntry() {
    let inbox = Self.seededInbox()
    let result = InboxFilter.apply(.all, to: inbox)
    #expect(result.count == 5)
    #expect(result.allSatisfy { $0.dismissedAt == nil })
  }

  @Test
  func unreadReturnsOnlyIsUnreadEntries() {
    let inbox = Self.seededInbox()
    let result = InboxFilter.apply(.unread, to: inbox)
    #expect(result.allSatisfy { $0.isUnread })
  }

  @Test
  func waitingReturnsOnlyBlockedOnInput() {
    let inbox = Self.seededInbox()
    let result = InboxFilter.apply(.waiting, to: inbox)
    #expect(result.allSatisfy { $0.kind == .blockedOnInput })
    #expect(result.count == 1)
  }

  @Test
  func completedReturnsOnlyCompleted() {
    let inbox = Self.seededInbox()
    let result = InboxFilter.apply(.completed, to: inbox)
    #expect(result.allSatisfy { $0.kind == .completed })
    #expect(result.count == 2)
  }

  @Test
  func crashedReturnsOnlyCrashed() {
    let inbox = Self.seededInbox()
    let result = InboxFilter.apply(.crashed, to: inbox)
    #expect(result.allSatisfy { $0.kind == .crashed })
    #expect(result.count == 1)
  }

  @Test
  func dismissedEntriesAreFilteredOutFromEveryChip() {
    let inbox = Self.seededInbox(includeDismissed: true)
    for filter in InboxFilter.allCases {
      let result = InboxFilter.apply(filter, to: inbox)
      #expect(result.allSatisfy { $0.dismissedAt == nil },
              "Filter \(filter) leaked dismissed entries")
    }
  }

  @Test
  func everyFilterHasStableTitle() {
    for filter in InboxFilter.allCases {
      #expect(!filter.title.isEmpty)
    }
  }

  // MARK: - Helpers

  private static func seededInbox(includeDismissed: Bool = false) -> [AgentNotification] {
    // 5 notifications + optional 2 dismissed variants.
    var list: [AgentNotification] = [
      Self.make(kind: .completed, agent: "claude", read: false),
      Self.make(kind: .completed, agent: "codex", read: true),
      Self.make(kind: .blockedOnInput, agent: "claude", read: false),
      Self.make(kind: .idle, agent: "aider", read: true),
      Self.make(kind: .crashed, agent: "codex", read: false),
    ]
    if includeDismissed {
      list.append(Self.make(kind: .completed, agent: "claude", read: false, dismissed: true))
      list.append(Self.make(kind: .blockedOnInput, agent: "aider", read: false, dismissed: true))
    }
    return list
  }

  private static func make(
    kind: AgentNotification.Kind,
    agent: String,
    read: Bool,
    dismissed: Bool = false
  ) -> AgentNotification {
    AgentNotification(
      panelID: PanelID(),
      agent: agent,
      kind: kind,
      title: "t",
      body: "b",
      createdAt: Date(timeIntervalSince1970: 0),
      readAt: read ? Date() : nil,
      dismissedAt: dismissed ? Date() : nil
    )
  }
}
