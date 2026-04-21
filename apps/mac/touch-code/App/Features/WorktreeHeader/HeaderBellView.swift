import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Bell button + unread badge + popover host. Badge count is derived live
/// from `WorktreeHeaderFeature.State.unreadCount(in:)` against the current
/// `hierarchyManager.catalog`, so the badge tracks both inbox mutations
/// (via TCA state updates) and catalog mutations (via `@Observable`
/// re-renders) without a cached field.
struct HeaderBellView: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let count = store.state.unreadCount(in: hierarchyManager.catalog)
    Button {
      store.send(.popoverToggled(!store.popoverOpen))
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "bell")
          .imageScale(.medium)
          .padding(2)
        if count > 0 {
          badge(count: count)
            .offset(x: 6, y: -4)
        }
      }
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Notifications, \(count) unread")
    .help(count == 0 ? "No notifications" : "\(count) unread")
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

  private func badge(count: Int) -> some View {
    Text("\(min(count, 99))")
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Color.red, in: Capsule())
  }
}
