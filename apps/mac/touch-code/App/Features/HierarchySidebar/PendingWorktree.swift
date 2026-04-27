import Foundation
import TouchCodeCore

/// In-memory placeholder for a worktree whose `wt sw` is still streaming.
/// Lives on `HierarchySidebarFeature.State.pendingWorktrees`. Distinct
/// from the persistent `Worktree` (catalog) — pending rows have no on-disk
/// presence in catalog.json, no `WorktreeID`, no Tab/Pane attachment, and
/// vanish on app restart. See `docs/design-docs/worktree-sidebar-ordering.md`
/// §pending 段 for the full contract.
nonisolated struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init() { raw = UUID() }
  init(_ raw: UUID) { self.raw = raw }
}

struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let spec: CreateWorktreeSpec
  let displayName: String
  var status: Status
  var lastProgressLine: String?
  let startedAt: Date

  enum Status: Equatable {
    case running
    case failed(GitWorktreeError)
  }
}
