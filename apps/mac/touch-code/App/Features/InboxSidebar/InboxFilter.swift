import Foundation
import TouchCodeCore

/// Filter chips in the inbox sidebar header. `all` shows every
/// non-dismissed notification; the others narrow by kind (`unread` is
/// the Dock-badge set).
nonisolated enum InboxFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
  case all
  case unread
  case waiting     // kind == .blockedOnInput
  case completed   // kind == .completed
  case crashed     // kind == .crashed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "All"
    case .unread: return "Unread"
    case .waiting: return "Waiting"
    case .completed: return "Completed"
    case .crashed: return "Crashed"
    }
  }

  /// Pure filter over the inbox. Dismissed entries are always excluded —
  /// soft-delete moves them out of every chip view until the 7-day sweep.
  static func apply(_ filter: InboxFilter, to notifications: [AgentNotification]) -> [AgentNotification] {
    let visible = notifications.filter { $0.dismissedAt == nil }
    switch filter {
    case .all:
      return visible
    case .unread:
      return visible.filter { $0.isUnread }
    case .waiting:
      return visible.filter { $0.kind == .blockedOnInput }
    case .completed:
      return visible.filter { $0.kind == .completed }
    case .crashed:
      return visible.filter { $0.kind == .crashed }
    }
  }
}
