import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Bell popover contents: header row ("Notifications" + Dismiss all),
/// then unread notifications grouped Project -> Worktree. Rows fire
/// `.notificationTapped(...)`. Empty state shows "No notifications".
///
/// The projection derives from the feature's cached inbox + the live
/// `@Environment(HierarchyManager.self).catalog`; orphaned panes (no
/// longer present in the catalog) drop out — same policy as the badge
/// count so the rendered row count equals `store.unreadCount`.
struct HeaderBellPopover: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let catalog = hierarchyManager.catalog
    let groups = Self.groupProjectByWorktree(inbox: store.inbox, catalog: catalog)
    let hasUnread = store.state.unreadCount(in: catalog) > 0
    VStack(alignment: .leading, spacing: 0) {
      header(hasUnread: hasUnread)
      Divider()
      if groups.isEmpty {
        emptyState
      } else {
        list(groups: groups)
      }
    }
    .frame(minWidth: 320, idealWidth: 360, maxHeight: 420)
  }

  private func header(hasUnread: Bool) -> some View {
    HStack {
      Text("Notifications")
        .font(.headline)
      Spacer()
      Button("Dismiss all") {
        store.send(.dismissAllTapped)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(!hasUnread)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    Text("No notifications")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 80)
  }

  private func list(groups: [ProjectGroup]) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(groups) { group in
          Text(group.projectName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
          ForEach(group.worktrees) { worktreeGroup in
            Text(worktreeGroup.branchLabel)
              .font(.footnote.weight(.medium))
              .padding(.horizontal, 16)
            ForEach(worktreeGroup.notifications) { notification in
              row(
                notification: notification,
                projectID: group.projectID,
                worktreeID: worktreeGroup.worktreeID
              )
            }
          }
        }
      }
      .padding(.vertical, 6)
    }
  }

  private func row(
    notification: AgentNotification,
    projectID: ProjectID,
    worktreeID: WorktreeID
  ) -> some View {
    Button {
      store.send(
        .notificationTapped(
          projectID: projectID, worktreeID: worktreeID
        ))
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.turn.down.right")
          .imageScale(.small)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(notification.title)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer()
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 20)
      .padding(.vertical, 4)
    }
    .buttonStyle(.borderless)
  }
}

extension HeaderBellPopover {
  /// Popover row model — keyed bucket of unread notifications per Worktree
  /// under a Project. Only unread, non-dismissed entries appear, matching
  /// the badge count policy.
  struct WorktreeGroup: Identifiable, Equatable {
    let worktreeID: WorktreeID
    let branchLabel: String
    let notifications: [AgentNotification]
    var id: WorktreeID { worktreeID }
  }

  struct ProjectGroup: Identifiable, Equatable {
    let projectID: ProjectID
    let projectName: String
    let worktrees: [WorktreeGroup]
    var id: ProjectID { projectID }
  }

  /// Builds the Project -> Worktree -> [unread notifications] grouping
  /// from a flat inbox + the current catalog. One walk of the catalog to
  /// build the `PaneID -> (Space, Project, Worktree, branch)` map;
  /// one walk of the notifications to bucket them. Orphans drop out.
  static func groupProjectByWorktree(
    inbox: NotificationInbox,
    catalog: Catalog
  ) -> [ProjectGroup] {
    struct PaneLocation {
      let projectID: ProjectID
      let projectName: String
      let worktreeID: WorktreeID
      let branchLabel: String
    }
    var paneMap: [PaneID: PaneLocation] = [:]
    for project in catalog.projects {
      for worktree in project.worktrees {
        let branch = worktree.branch ?? worktree.name
        for tab in worktree.tabs {
          for pane in tab.panes {
            paneMap[pane.id] = PaneLocation(
              projectID: project.id,
              projectName: project.name,
              worktreeID: worktree.id,
              branchLabel: branch
            )
          }
        }
      }
    }

    // Bucket unreads by (Project, Worktree) preserving first-seen catalog order.
    var projectOrder: [ProjectID] = []
    var projectMeta: [ProjectID: (name: String, worktreeOrder: [WorktreeID])] = [:]
    var worktreeMeta: [WorktreeID: (projectID: ProjectID, branchLabel: String)] = [:]
    var bucket: [WorktreeID: [AgentNotification]] = [:]

    for notification in inbox.notifications where notification.isUnread {
      guard let location = paneMap[notification.paneID] else { continue }
      if projectMeta[location.projectID] == nil {
        projectMeta[location.projectID] = (location.projectName, [])
        projectOrder.append(location.projectID)
      }
      if worktreeMeta[location.worktreeID] == nil {
        worktreeMeta[location.worktreeID] = (location.projectID, location.branchLabel)
        projectMeta[location.projectID]?.worktreeOrder.append(location.worktreeID)
      }
      bucket[location.worktreeID, default: []].append(notification)
    }

    return projectOrder.map { projectID in
      let meta = projectMeta[projectID]!
      let worktreeGroups: [WorktreeGroup] = meta.worktreeOrder.map { worktreeID in
        WorktreeGroup(
          worktreeID: worktreeID,
          branchLabel: worktreeMeta[worktreeID]!.branchLabel,
          notifications: bucket[worktreeID] ?? []
        )
      }
      return ProjectGroup(
        projectID: projectID,
        projectName: meta.name,
        worktrees: worktreeGroups
      )
    }
  }
}
