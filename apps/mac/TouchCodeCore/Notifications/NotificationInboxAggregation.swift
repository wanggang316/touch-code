import Foundation

/// Aggregation helpers that project the flat `PanelID`-keyed inbox onto the
/// Worktree / Project / Space hierarchy in a given `Catalog`. Each call
/// rebuilds a `[PanelID: WorktreeID]` index from the catalog, so render-hot
/// paths (for example sidebars rendering one row per Project or per Worktree)
/// should cache a snapshot-scoped index instead of calling these per-row.
///
/// All helpers filter by `AgentNotification.isUnread` except
/// `notifications(forWorktree:in:)`, which returns every entry keyed to the
/// worktree regardless of read/dismissed state and leaves filtering to the
/// caller.
extension NotificationInbox {
  /// Render-hot paths should cache a snapshot-scoped index.
  /// Returns the number of unread, non-dismissed notifications whose panel
  /// resolves to the given Worktree. Panels that no longer belong to any
  /// catalog worktree are skipped.
  public func unreadCount(forWorktree worktreeID: WorktreeID, in catalog: Catalog) -> Int {
    let index = catalog.panelWorktreeIndex()
    return notifications.reduce(into: 0) { total, notification in
      guard notification.isUnread else { return }
      guard index[notification.panelID] == worktreeID else { return }
      total += 1
    }
  }

  /// Render-hot paths should cache a snapshot-scoped index.
  /// Returns `true` iff at least one unread, non-dismissed notification
  /// resolves to a Worktree under the given Project.
  public func hasUnread(forProject projectID: ProjectID, in catalog: Catalog) -> Bool {
    guard let worktreeIDs = catalog.worktreeIDs(inProject: projectID), !worktreeIDs.isEmpty else {
      return false
    }
    let index = catalog.panelWorktreeIndex()
    return notifications.contains { notification in
      guard notification.isUnread else { return false }
      guard let worktreeID = index[notification.panelID] else { return false }
      return worktreeIDs.contains(worktreeID)
    }
  }

  /// Render-hot paths should cache a snapshot-scoped index.
  /// Returns `true` iff at least one unread, non-dismissed notification
  /// resolves to any Worktree of any Project in the given Space.
  public func hasUnread(forSpace spaceID: SpaceID, in catalog: Catalog) -> Bool {
    guard let worktreeIDs = catalog.worktreeIDs(inSpace: spaceID), !worktreeIDs.isEmpty else {
      return false
    }
    let index = catalog.panelWorktreeIndex()
    return notifications.contains { notification in
      guard notification.isUnread else { return false }
      guard let worktreeID = index[notification.panelID] else { return false }
      return worktreeIDs.contains(worktreeID)
    }
  }

  /// Render-hot paths should cache a snapshot-scoped index.
  /// Counts unread, non-dismissed notifications whose panel resolves to
  /// some Worktree in the given catalog. Shared by the Header bell badge
  /// (T2) and intended as the canonical "total resolvable unread"
  /// accessor across the catalog. Orphans — unread entries whose
  /// `panelID` no longer resolves to any Worktree — are excluded so the
  /// badge count and the popover grouping derived from
  /// `panelWorktreeIndex()` agree on the visible row count.
  public func totalUnread(in catalog: Catalog) -> Int {
    let index = catalog.panelWorktreeIndex()
    return notifications.reduce(into: 0) { total, notification in
      guard notification.isUnread else { return }
      guard index[notification.panelID] != nil else { return }
      total += 1
    }
  }

  /// Render-hot paths should cache a snapshot-scoped index.
  /// Every notification whose panel resolves to the given Worktree, sorted
  /// newest-first by `createdAt`; ties broken by `id` to ensure
  /// deterministic ordering. Includes read and dismissed entries; the
  /// caller filters as needed (for example, the bell popover elides
  /// dismissed entries but keeps read ones for history).
  public func notifications(forWorktree worktreeID: WorktreeID, in catalog: Catalog) -> [AgentNotification] {
    let index = catalog.panelWorktreeIndex()
    return
      notifications
      .filter { index[$0.panelID] == worktreeID }
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }
}

extension Catalog {
  /// `[PanelID: WorktreeID]` over every panel in the catalog. Built from one
  /// walk of the hierarchy. Public so render-hot callers can build the index
  /// once per snapshot and feed it into inline aggregation, sidestepping the
  /// per-call rebuild the `NotificationInbox.*(forWorktree:in:)` helpers do.
  /// Keep using the helpers when you only need one or two lookups; reach for
  /// this raw index when you're iterating over many worktrees/projects in the
  /// same render pass.
  public nonisolated func panelWorktreeIndex() -> [PanelID: WorktreeID] {
    var index: [PanelID: WorktreeID] = [:]
    for space in spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            for panel in tab.panels {
              index[panel.id] = worktree.id
            }
          }
        }
      }
    }
    return index
  }

  /// Every Worktree directly under the given Project, if the Project exists
  /// in this Catalog. Returns `nil` — not an empty set — for unknown
  /// Projects so callers can distinguish "no unread" from "no such Project".
  nonisolated func worktreeIDs(inProject projectID: ProjectID) -> Set<WorktreeID>? {
    for space in spaces {
      guard let project = space.projects.first(where: { $0.id == projectID }) else { continue }
      return Set(project.worktrees.map(\.id))
    }
    return nil
  }

  /// Every Worktree under every Project of the given Space, if the Space
  /// exists. Returns `nil` for unknown Spaces (same rationale as
  /// `worktreeIDs(inProject:)`).
  nonisolated func worktreeIDs(inSpace spaceID: SpaceID) -> Set<WorktreeID>? {
    guard let space = spaces.first(where: { $0.id == spaceID }) else { return nil }
    var ids: Set<WorktreeID> = []
    for project in space.projects {
      for worktree in project.worktrees {
        ids.insert(worktree.id)
      }
    }
    return ids
  }
}
