import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Bell button + unread badge + popover host. Badge counts are fed by
/// `WorktreeHeaderFeature.unreadCount` (catalog-resolvable global unread).
struct HeaderBellView: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>

  var body: some View {
    Button {
      store.send(.popoverToggled(!store.popoverOpen))
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "bell")
          .imageScale(.medium)
          .padding(2)
        if store.unreadCount > 0 {
          badge
            .offset(x: 6, y: -4)
        }
      }
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Notifications, \(store.unreadCount) unread")
    .help(store.unreadCount == 0 ? "No notifications" : "\(store.unreadCount) unread")
    .popover(
      isPresented: Binding(
        get: { store.popoverOpen },
        set: { store.send(.popoverToggled($0)) }
      ),
      arrowEdge: .top
    ) {
      HeaderBellPopover(store: store)
    }
  }

  private var badge: some View {
    Text("\(min(store.unreadCount, 99))")
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Color.red, in: Capsule())
  }
}
