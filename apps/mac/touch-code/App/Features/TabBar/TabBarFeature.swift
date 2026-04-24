import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Tab bar reducer. State-free controller: Worktree.tabs is read from the
/// environment `HierarchyManager` at render time; actions dispatch create /
/// select / close / rename / reorder / bulk-close commands through
/// `HierarchyClient`. Errors are swallowed (logged via the client's own
/// channels) — tab-bar failures are rare and not worth modal UX today.
@Reducer
struct TabBarFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case newTabButtonTapped(
      inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case tabButtonTapped(
      TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case closeButtonTapped(
      TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)

    // Tab-bar uplift (M2-T2.2)
    case renameSubmitted(
      TabID, name: String?,
      inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case contextMenuCloseOthers(
      TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case contextMenuCloseToRight(
      TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case contextMenuCloseAll(
      inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case dragReorderEnded(
      orderedIDs: [TabID],
      inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case middleClicked(
      TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .newTabButtonTapped(let worktreeID, let projectID, let spaceID):
        guard let tabID = try? hierarchyClient.createTab(worktreeID, projectID, spaceID, nil)
        else { return .none }
        // Resolve worktree.path from the catalog so the auto-spawned pane
        // starts in the Worktree's directory instead of `$HOME`. Silent no-op
        // if the Worktree vanished between createTab and this lookup.
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog.spaces.first(where: { $0.id == spaceID })?
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })
        else { return .none }
        _ = try? hierarchyClient.openPane(
          tabID, worktreeID, projectID, spaceID, worktree.path, nil
        )
        return .none

      case .tabButtonTapped(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.selectTab(tabID, worktreeID, projectID, spaceID)
        return .none

      case .closeButtonTapped(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID, spaceID)
        return .none

      case .renameSubmitted(let tabID, let name, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.renameTab(tabID, worktreeID, projectID, spaceID, name)
        return .none

      case .contextMenuCloseOthers(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closeOtherTabs(tabID, worktreeID, projectID, spaceID)
        return .none

      case .contextMenuCloseToRight(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closeTabsToRight(tabID, worktreeID, projectID, spaceID)
        return .none

      case .contextMenuCloseAll(let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closeAllTabs(worktreeID, projectID, spaceID)
        return .none

      case .dragReorderEnded(let orderedIDs, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.reorderTabs(worktreeID, projectID, spaceID, orderedIDs)
        return .none

      case .middleClicked(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID, spaceID)
        return .none
      }
    }
  }
}
