import ComposableArchitecture
import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

@MainActor
struct InboxSidebarFeatureTests {
  @Test
  func filterChangedUpdatesState() async throws {
    let store = TestStore(initialState: InboxSidebarFeature.State()) {
      InboxSidebarFeature()
    }
    await store.send(.filterChanged(.waiting)) {
      $0.filter = .waiting
    }
  }

  @Test
  func inboxUpdatedOverwritesNotifications() async throws {
    let store = TestStore(initialState: InboxSidebarFeature.State()) {
      InboxSidebarFeature()
    }
    let entry = AgentNotification(
      panelID: PanelID(),
      agent: "claude",
      kind: .completed,
      title: "t",
      body: "b",
      createdAt: Date(timeIntervalSince1970: 0)
    )
    let inbox = NotificationInbox(notifications: [entry])
    await store.send(.inboxUpdated(inbox)) {
      $0.notifications = [entry]
    }
  }

  @Test
  func unreadCountUpdatedStoresValue() async throws {
    let store = TestStore(initialState: InboxSidebarFeature.State()) {
      InboxSidebarFeature()
    }
    await store.send(.unreadCountUpdated(3)) {
      $0.unreadCount = 3
    }
  }

  @Test
  func rowTappedMarksReadAndEmitsDeeplink() async throws {
    let entry = AgentNotification(
      panelID: PanelID(),
      agent: "claude",
      kind: .completed,
      title: "t",
      body: "b",
      createdAt: Date(timeIntervalSince1970: 0)
    )
    let markReadCalls = LockIsolated<[[UUID]]>([])
    let store = TestStore(
      initialState: InboxSidebarFeature.State(notifications: [entry])
    ) {
      InboxSidebarFeature()
    } withDependencies: {
      $0[InboxClient.self].markRead = { ids in
        markReadCalls.withValue { $0.append(ids) }
      }
    }

    await store.send(.rowTapped(entry.id))
    await store.receive(.deeplinkRequested(entry.panelID))
    #expect(markReadCalls.value == [[entry.id]])
  }

  @Test
  func rowSwipedDismissForwardsToClient() async throws {
    let id = UUID()
    let dismissCalls = LockIsolated<[[UUID]]>([])
    let store = TestStore(initialState: InboxSidebarFeature.State()) {
      InboxSidebarFeature()
    } withDependencies: {
      $0[InboxClient.self].dismiss = { ids in
        dismissCalls.withValue { $0.append(ids) }
      }
    }

    await store.send(.rowSwipedDismiss(id))
    #expect(dismissCalls.value == [[id]])
  }

  @Test
  func muteRuleTappedForwardsToClient() async throws {
    let muteCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: InboxSidebarFeature.State()) {
      InboxSidebarFeature()
    } withDependencies: {
      $0[InboxClient.self].muteRule = { id in
        muteCalls.withValue { $0.append(id) }
      }
    }

    await store.send(.muteRuleTapped(ruleID: "claude.done"))
    #expect(muteCalls.value == ["claude.done"])
  }

  @Test
  func clearAllTappedForwardsToClient() async throws {
    let clearCalls = LockIsolated(0)
    let store = TestStore(initialState: InboxSidebarFeature.State()) {
      InboxSidebarFeature()
    } withDependencies: {
      $0[InboxClient.self].clearAll = {
        clearCalls.withValue { $0 += 1 }
      }
    }

    await store.send(.clearAllTapped)
    #expect(clearCalls.value == 1)
  }
}

// MARK: - State init convenience for tests

@MainActor
extension InboxSidebarFeature.State {
  fileprivate init(notifications: [AgentNotification]) {
    self.init()
    self.notifications = notifications
  }
}
