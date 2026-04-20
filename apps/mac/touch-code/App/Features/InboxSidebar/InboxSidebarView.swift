import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Replaces `InboxSidebarPlaceholder`. Renders the C6 agent-notification
/// inbox as the leading column's "inbox" mode (per 0007 DEC-2, option
/// (b) mode-swap). Filter chips top, scrolling list below, trailing
/// "Clear all" action when non-empty.
struct InboxSidebarView: View {
  @Bindable var store: StoreOf<InboxSidebarFeature>

  var body: some View {
    VStack(spacing: 0) {
      filterBar

      Divider()

      content
    }
    .task { store.send(.onAppear) }
  }

  // MARK: - Filter bar

  private var filterBar: some View {
    HStack(spacing: 8) {
      Picker("Filter", selection: Binding(
        get: { store.filter },
        set: { store.send(.filterChanged($0)) }
      )) {
        ForEach(InboxFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if !visibleNotifications.isEmpty {
        Button {
          store.send(.clearAllTapped)
        } label: {
          Image(systemName: "tray")
            .accessibilityLabel("Clear all")
        }
        .buttonStyle(.plain)
        .help("Clear all notifications")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if visibleNotifications.isEmpty {
      emptyState
    } else {
      List(visibleNotifications) { notification in
        InboxRow(notification: notification)
          .contentShape(Rectangle())
          .accessibilityAddTraits(.isButton)
          .onTapGesture {
            store.send(.rowTapped(notification.id))
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              store.send(.rowSwipedDismiss(notification.id))
            } label: {
              Label("Dismiss", systemImage: "xmark.bin")
            }
            .tint(.red)
          }
          .contextMenu {
            Button("Mute rule") {
              if let ruleID = ruleID(for: notification) {
                store.send(.muteRuleTapped(ruleID: ruleID))
              }
            }
            .disabled(ruleID(for: notification) == nil)
            Button("Dismiss") {
              store.send(.rowSwipedDismiss(notification.id))
            }
          }
      }
      .listStyle(.sidebar)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "bell.badge")
        .accessibilityHidden(true)
        .font(.title)
        .foregroundStyle(.secondary)
      Text(emptyStateCopy)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateCopy: String {
    switch store.filter {
    case .all: return "No agent pings. Nice."
    case .unread: return "Caught up — no unread notifications."
    case .waiting: return "No agents are waiting for input."
    case .completed: return "No completed agent sessions yet."
    case .crashed: return "No agent crashes. Good."
    }
  }

  private var visibleNotifications: [AgentNotification] {
    InboxFilter.apply(store.filter, to: store.notifications)
  }

  /// Best-effort rule-id extraction for the "Mute rule" context item.
  /// Not every notification carries the originating rule id on its face
  /// — the design keeps the rule identity one hop away in the inbox
  /// entry. For M5 we surface Mute only when the notification's kind
  /// pair with the rule id can be reconstructed later; absent that, the
  /// menu item is disabled.
  private func ruleID(for notification: AgentNotification) -> String? {
    // AgentNotification does not currently carry ruleID — the M5 UI
    // surfaces the feature behind an explicit disable until
    // AgentNotification grows the field (follow-up, not blocking). The
    // action handler no-ops for now.
    _ = notification
    return nil
  }
}

// MARK: - Row

struct InboxRow: View {
  let notification: AgentNotification

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      avatar
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(notification.title)
            .font(.body.weight(notification.isUnread ? .semibold : .regular))
            .lineLimit(1)
          Spacer()
          stateChip
        }
        if !notification.body.isEmpty {
          Text(notification.body)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(notification.createdAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }

  private var avatar: some View {
    ZStack {
      Circle()
        .fill(.quaternary)
        .frame(width: 28, height: 28)
      Text(String(notification.agent.prefix(1).uppercased()))
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
    .accessibilityLabel("Agent \(notification.agent)")
  }

  private var stateChip: some View {
    Text(stateChipTitle)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(stateChipColor.opacity(0.15))
      .foregroundStyle(stateChipColor)
      .clipShape(Capsule())
  }

  private var stateChipTitle: String {
    switch notification.kind {
    case .completed: return "Done"
    case .blockedOnInput: return "Waiting"
    case .idle: return "Idle"
    case .crashed: return "Crashed"
    }
  }

  private var stateChipColor: Color {
    switch notification.kind {
    case .completed: return .green
    case .blockedOnInput: return .orange
    case .idle: return .gray
    case .crashed: return .red
    }
  }
}
