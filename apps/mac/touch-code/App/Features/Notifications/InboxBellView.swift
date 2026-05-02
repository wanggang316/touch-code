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
    let count = rollup?.current.globalUnreadCount ?? 0
    Button(action: { popoverShown.toggle() }) {
      HStack(spacing: 4) {
        Image(systemName: count > 0 ? "bell.fill" : "bell")
          .font(.title3)
          .foregroundStyle(count > 0 ? Color.orange : Color.primary)
        if count > 0 {
          Text(badgeLabel(count))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
        }
      }
      // Symmetric horizontal inset so the bell + digits sit centred
      // inside the toolbar capsule on macOS 26 (and so the digits
      // never crowd the right edge). Previously this was trailing-only,
      // which made the button visibly off-centre.
      .padding(.horizontal, 6)
      .frame(minHeight: 24)
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

  @Environment(HierarchyManager.self) private var hierarchyManager: HierarchyManager?
  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 8) {
        // Leading 6 px slot. Filled circle on unread (yellow for
        // taskFinished, orange for the more urgent waitingForInput);
        // empty space on read so we never show a check-shaped icon
        // in front of an unread row (the previous green
        // checkmark.circle.fill read as 'already done' and was the
        // bug Gump flagged).
        unreadDot
          .frame(width: 6, height: 6)
          .padding(.top, 7)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(entry.title)
              .font(.callout)
              .fontWeight(entry.isUnread ? .semibold : .regular)
              .foregroundStyle(entry.isUnread ? Color.primary : Color.secondary)
              .lineLimit(1)
            Spacer()
            if let projectName, !projectName.isEmpty {
              Text(projectName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
              Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Text(relativeAge)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Text(entry.body)
            .font(.caption)
            .foregroundStyle(entry.isUnread ? Color.secondary : Color.secondary.opacity(0.7))
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

  /// Read state has no leading glyph (a check-shape next to a row reads
  /// as "this is done/read" and conflicts with the unread row case).
  /// Unread state shows a filled dot whose colour mirrors the kind:
  /// orange for waitingForInput (more urgent), yellow for taskFinished
  /// (matches the bell glyph theme).
  @ViewBuilder
  private var unreadDot: some View {
    if entry.isUnread {
      Circle()
        .fill(entry.kind == .waitingForInput ? Color.orange : Color.yellow)
        .accessibilityLabel(entry.kind == .waitingForInput ? "Waiting for input" : "Unread")
    } else {
      Color.clear
    }
  }

  /// Project display name for the entry's source path. Resolved live
  /// from `HierarchyManager.catalog` so a project rename reflects in
  /// the popover without a save / reload cycle. Returns nil when the
  /// project has been deleted (G3 dead-target case) — the row simply
  /// omits the breadcrumb in that case.
  private var projectName: String? {
    guard let mgr = hierarchyManager else { return nil }
    return mgr.catalog.projects.first(where: { $0.id == entry.source.projectID })?.name
  }

  private var relativeAge: String {
    Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date())
  }
}
