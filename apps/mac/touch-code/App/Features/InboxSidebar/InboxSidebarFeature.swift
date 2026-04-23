import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer for the agent-notification inbox sidebar (C6 M5). Owns the
/// active filter chip, the list of visible notifications, and the
/// Dock-facing unread count. Structural source-of-truth lives in
/// `InboxStore` behind `InboxClient`; this state is a cached projection
/// that reflects the latest snapshot seen on the observe stream.
///
/// Row-tap and banner-click ultimately focus the originating Pane, but
/// the navigation chain lives in `RootFeature` — this reducer emits
/// `.deeplinkRequested(PaneID)` as a delegate action and leaves the
/// actual hierarchy selection to the parent (design sketch
/// §Deeplink chain).
@Reducer
struct InboxSidebarFeature {
  @ObservableState
  struct State: Equatable {
    var filter: InboxFilter = .all
    var notifications: [AgentNotification] = []
    var unreadCount: Int = 0
  }

  enum Action: Equatable {
    case onAppear
    case filterChanged(InboxFilter)
    case rowTapped(AgentNotification.ID)
    case rowSwipedDismiss(AgentNotification.ID)
    case muteRuleTapped(ruleID: String)
    case clearAllTapped

    case inboxUpdated(NotificationInbox)
    case unreadCountUpdated(Int)

    /// Delegate action — parent reducer (RootFeature) focuses the
    /// originating Pane via HierarchyClient.
    case deeplinkRequested(PaneID)
  }

  nonisolated enum CancelID: Sendable { case observe, observeUnread }

  @Dependency(InboxClient.self) private var inboxClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let observeStream = inboxClient.observe()
        let unreadStream = inboxClient.observeUnread()
        return .merge(
          .run { send in
            for await inbox in observeStream {
              await send(.inboxUpdated(inbox))
            }
          }
          .cancellable(id: CancelID.observe, cancelInFlight: true),
          .run { send in
            for await count in unreadStream {
              await send(.unreadCountUpdated(count))
            }
          }
          .cancellable(id: CancelID.observeUnread, cancelInFlight: true)
        )

      case .filterChanged(let filter):
        state.filter = filter
        return .none

      case .rowTapped(let id):
        // Stale-row guard: the id may refer to a notification that was
        // dismissed between render and tap (the SwiftUI List held a
        // stale snapshot during the animation window). `markRead` is
        // idempotent against unknown ids; we skip the deeplink emit if
        // the entry is no longer in the cached projection.
        let paneID = state.notifications.first(where: { $0.id == id })?.paneID
        inboxClient.markRead([id])
        if let paneID {
          return .send(.deeplinkRequested(paneID))
        }
        return .none

      case .rowSwipedDismiss(let id):
        inboxClient.dismiss([id])
        return .none

      case .muteRuleTapped(let ruleID):
        inboxClient.muteRule(ruleID)
        return .none

      case .clearAllTapped:
        inboxClient.clearAll()
        return .none

      case .inboxUpdated(let inbox):
        state.notifications = inbox.notifications
        return .none

      case .unreadCountUpdated(let count):
        state.unreadCount = count
        return .none

      case .deeplinkRequested:
        // Consumed upstream; this reducer has no local state change.
        return .none
      }
    }
  }
}
