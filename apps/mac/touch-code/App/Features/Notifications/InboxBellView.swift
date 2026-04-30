import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// v1 status-bar bell. Renders a `bell` SF Symbol with an unread-count
/// badge sourced from `RollupIndexProvider.current.globalUnreadCount`.
/// Tapping anchors a popover that lists the inbox newest-first; clicking
/// a row dispatches `RootFeature.focusHierarchyPath` and marks the row
/// read.
///
/// This is the only popover entry into the inbox. Per-level indicators
/// in the sidebar / tab bar / pane chrome are visual-only.
struct InboxBellView: View {
  /// Dispatches `RootFeature.focusHierarchyPath` for a tapped row.
  /// Wired by ContentView; passing a closure rather than the root store
  /// keeps WorktreeDetailView from needing the full RootFeature scope.
  let onFocusHierarchyPath: (InboxEntry.SourcePath) -> Void
  @Environment(NotificationStore.self) private var inbox: NotificationStore?
  @Environment(RollupIndexProvider.self) private var rollup: RollupIndexProvider?

  @State private var popoverShown = false
  @State private var unreadOnly = false

  var body: some View {
    Button(action: { popoverShown.toggle() }) {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "bell")
          .font(.body)
          .foregroundStyle(.primary)
        if let count = rollup?.current.globalUnreadCount, count > 0 {
          Text(badgeLabel(count))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red))
            .offset(x: 6, y: -4)
        }
      }
      .frame(minWidth: 24, minHeight: 20)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .popover(isPresented: $popoverShown, arrowEdge: .top) {
      InboxPopoverContent(
        unreadOnly: $unreadOnly,
        onRowTap: { entry in
          inbox?.markRead(id: entry.id)
          popoverShown = false
          onFocusHierarchyPath(entry.source)
        },
        onMarkAllRead: { inbox?.markAllRead() }
      )
      .frame(minWidth: 320, idealWidth: 360, maxWidth: 480, minHeight: 200, idealHeight: 360)
    }
  }

  private func badgeLabel(_ count: Int) -> String {
    count >= 100 ? "99+" : String(count)
  }

  private var accessibilityLabel: String {
    let count = rollup?.current.globalUnreadCount ?? 0
    if count == 0 { return "Notifications: no unread" }
    return "Notifications: \(count) unread"
  }
}

/// Popover body. Holds the row list + filter chip + Mark all read.
private struct InboxPopoverContent: View {
  @Binding var unreadOnly: Bool
  let onRowTap: (InboxEntry) -> Void
  let onMarkAllRead: () -> Void

  @Environment(NotificationStore.self) private var inbox: NotificationStore?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if filtered.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filtered) { entry in
              InboxRowView(entry: entry, onTap: { onRowTap(entry) })
              Divider()
            }
          }
        }
      }
    }
  }

  private var filtered: [InboxEntry] {
    let entries = inbox?.entries ?? []
    return unreadOnly ? entries.filter(\.isUnread) : entries
  }

  private var header: some View {
    HStack(spacing: 12) {
      Text("Notifications")
        .font(.headline)
      Spacer()
      Picker("", selection: $unreadOnly) {
        Text("All").tag(false)
        Text("Unread").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 140)

      Button("Mark all read", action: onMarkAllRead)
        .buttonStyle(.plain)
        .font(.caption)
        .disabled((inbox?.unreadCount ?? 0) == 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "tray")
        .font(.title)
        .foregroundStyle(.secondary)
      Text(unreadOnly ? "No unread notifications" : "No notifications yet")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

private struct InboxRowView: View {
  let entry: InboxEntry
  let onTap: () -> Void

  /// Formatter is allocated once for the whole popover lifetime; building
  /// a fresh `RelativeDateTimeFormatter` per row would otherwise spin up
  /// a CFLocale, calendar, and ICU context on every redraw.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 8) {
        kindIcon
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(entry.title)
              .font(.callout)
              .fontWeight(entry.isUnread ? .semibold : .regular)
              .lineLimit(1)
            Spacer()
            Text(relativeAge)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Text(entry.body)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(isHovering ? Color.gray.opacity(0.08) : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var kindIcon: some View {
    Image(systemName: entry.kind == .waitingForInput ? "hand.raised.fill" : "checkmark.circle.fill")
      .font(.caption)
      .foregroundStyle(entry.kind == .waitingForInput ? Color.orange : Color.green)
  }

  private var relativeAge: String {
    Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date())
  }
}
