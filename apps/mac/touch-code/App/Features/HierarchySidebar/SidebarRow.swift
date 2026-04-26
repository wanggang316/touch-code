import Foundation
import TouchCodeCore

/// Stable identity for a pending-create row that does not yet have a
/// `WorktreeID`. Distinct nominal type so SwiftUI / TCA cannot accidentally
/// confuse it with `WorktreeID`. Both wrap `UUID`; `SidebarRow.id` adds a
/// case prefix so `ForEach` does not collide on the raw UUID.
struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init(raw: UUID = UUID()) { self.raw = raw }
}

/// Sidebar-only "creation in flight" placeholder. task02 ships the minimal
/// stub fields needed by `SidebarRow` + `orderedSidebarRows`; task03 will
/// replace it with the full schema (adds `spaceID`, `spec`, `status`,
/// `lastProgressLine`, `startedAt`) per
/// docs/design-docs/worktree-sidebar-ordering.md §pending 段.
struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let displayName: String
}

/// Heterogeneous sidebar row. The pinned/unpinned segments render real
/// `Worktree`s from the catalog; the pending segment renders in-memory
/// `PendingWorktree`s while `wt sw` streams. `id` carries an explicit
/// case prefix so two UUID-backed identifiers cannot collide inside a
/// SwiftUI `ForEach`.
enum SidebarRow: Identifiable {
  case worktree(Worktree)
  case pending(PendingWorktree)

  var id: String {
    switch self {
    case .worktree(let w): return "wt:\(w.id.raw)"
    case .pending(let p): return "pending:\(p.id.raw)"
    }
  }
}
