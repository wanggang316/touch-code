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
  /// Sheet payload while the user is editing a tab's name. Lifted into the reducer
  /// (rather than left as `@State` in the view) so the global ⌘⇧R menu chord can
  /// surface the same sheet without a parallel presentation channel — the chord
  /// path resolves the active TabID in `RootFeature`, then dispatches
  /// `.renameRequested(...)` here, identical to the chip's right-click → Rename.
  struct RenameTarget: Identifiable, Equatable {
    let id: TabID
    let currentName: String
  }

  @ObservableState
  struct State: Equatable {
    var renameTarget: RenameTarget?
  }

  enum Action: Equatable {
    case newTabButtonTapped(inWorktree: WorktreeID, inProject: ProjectID)
    case tabButtonTapped(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case closeButtonTapped(TabID, inWorktree: WorktreeID, inProject: ProjectID)

    // Tab-bar uplift (M2-T2.2)
    /// Open the rename sheet for `tabID`. Sources: chip context-menu Rename
    /// (any tab) and `RootFeature.renameActiveTabForCurrentWorktreeRequested`
    /// (active tab via ⌘⇧R menu chord).
    case renameRequested(TabID, currentName: String)
    /// Sheet dismissal — driven by the user closing the sheet without
    /// committing. Commit path clears `renameTarget` inside `renameSubmitted`
    /// so the sheet animates away on Enter.
    case renameDismissed
    case renameSubmitted(
      TabID, name: String?, inWorktree: WorktreeID, inProject: ProjectID)
    case contextMenuCloseOthers(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case contextMenuCloseToRight(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case contextMenuCloseAll(inWorktree: WorktreeID, inProject: ProjectID)
    case dragReorderEnded(
      orderedIDs: [TabID], inWorktree: WorktreeID, inProject: ProjectID)
    case middleClicked(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    /// Trailing split button click. Resolves the active tab's leftmost
    /// leaf as the anchor pane and splits it in `direction`. Silent no-op
    /// if the worktree has no active tab or the tab has no panes. Upgrades
    /// to the last-focused pane when M3 lands.
    case trailingSplitRequested(
      direction: SplitTree<PaneID>.NewDirection,
      inWorktree: WorktreeID, inProject: ProjectID)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .renameRequested(let tabID, let currentName):
        state.renameTarget = RenameTarget(id: tabID, currentName: currentName)
        return .none

      case .renameDismissed:
        state.renameTarget = nil
        return .none

      case .newTabButtonTapped(let worktreeID, let projectID):
        guard let tabID = try? hierarchyClient.createTab(worktreeID, projectID, nil)
        else { return .none }
        // Resolve worktree.path from the catalog so the auto-spawned pane
        // starts in the Worktree's directory instead of `$HOME`. Silent no-op
        // if the Worktree vanished between createTab and this lookup.
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog.projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })
        else { return .none }
        _ = try? hierarchyClient.openPane(
          tabID, worktreeID, projectID, worktree.path, nil
        )
        return .none

      case .tabButtonTapped(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.selectTab(tabID, worktreeID, projectID)
        return .none

      case .closeButtonTapped(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID)
        return .none

      case .renameSubmitted(let tabID, let name, let worktreeID, let projectID):
        try? hierarchyClient.renameTab(tabID, worktreeID, projectID, name)
        state.renameTarget = nil
        return .none

      case .contextMenuCloseOthers(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeOtherTabs(tabID, worktreeID, projectID)
        return .none

      case .contextMenuCloseToRight(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeTabsToRight(tabID, worktreeID, projectID)
        return .none

      case .contextMenuCloseAll(let worktreeID, let projectID):
        try? hierarchyClient.closeAllTabs(worktreeID, projectID)
        return .none

      case .dragReorderEnded(let orderedIDs, let worktreeID, let projectID):
        try? hierarchyClient.reorderTabs(worktreeID, projectID, orderedIDs)
        return .none

      case .middleClicked(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID)
        return .none

      case .trailingSplitRequested(let direction, let worktreeID, let projectID):
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog.projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let activeTabID = worktree.selectedTabID,
          let activeTab = worktree.tabs.first(where: { $0.id == activeTabID }),
          let anchor = activeTab.splitTree.leaves().first,
          let anchorPane = activeTab.panes.first(where: { $0.id == anchor })
        else { return .none }
        _ = try? hierarchyClient.splitPane(
          anchor, direction,
          activeTabID, worktreeID, projectID,
          anchorPane.workingDirectory, nil
        )
        return .none
      }
    }
  }
}
