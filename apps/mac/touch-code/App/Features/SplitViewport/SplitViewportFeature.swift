import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Split viewport reducer. Actions mutate the active Tab's `SplitTree`
/// through `HierarchyClient`; live panel surfaces are created / destroyed
/// through `TerminalClient`. Per DEC-3 the state seeds `activeTabID:
/// TabID?` so M5's lazy-surface lifecycle can react to `.tabActivated`
/// without state restructuring.
@Reducer
struct SplitViewportFeature {
  @ObservableState
  struct State: Equatable {
    /// The Tab currently rendered in the viewport. Set by parent features
    /// (RootFeature selection stream in M4; lazy lifecycle in M5).
    var activeTabID: TabID?
  }

  enum Action: Equatable {
    case activeTabChanged(TabID?)
    case newPanelButtonTapped(
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID,
      workingDirectory: String)
    case splitButtonTapped(
      PanelID, direction: SplitTree<PanelID>.NewDirection,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID,
      workingDirectory: String)
    case closePanelButtonTapped(
      PanelID, inTab: TabID, inWorktree: WorktreeID,
      inProject: ProjectID, inSpace: SpaceID)
    case focusPanelRequested(
      PanelID, inTab: TabID, inWorktree: WorktreeID,
      inProject: ProjectID, inSpace: SpaceID)
    case resizeSplitRequested(
      SplitTree<PanelID>.Path, ratio: Double,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .activeTabChanged(let tabID):
        state.activeTabID = tabID
        return .none

      case .newPanelButtonTapped(let tabID, let worktreeID, let projectID, let spaceID, let cwd):
        _ = try? hierarchyClient.openPanel(tabID, worktreeID, projectID, spaceID, cwd, nil)
        return .none

      case .splitButtonTapped(
        let panelID, let direction,
        let tabID, let worktreeID, let projectID, let spaceID, let cwd
      ):
        _ = try? hierarchyClient.splitPanel(
          panelID, direction, tabID, worktreeID, projectID, spaceID, cwd, nil
        )
        return .none

      case .closePanelButtonTapped(let panelID, let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closePanel(panelID, tabID, worktreeID, projectID, spaceID)
        return .none

      case .focusPanelRequested(let panelID, let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.focusPanel(panelID, tabID, worktreeID, projectID, spaceID)
        return .none

      case .resizeSplitRequested(
        let path, let ratio,
        let tabID, let worktreeID, let projectID, let spaceID
      ):
        try? hierarchyClient.resizeSplit(path, ratio, tabID, worktreeID, projectID, spaceID)
        return .none
      }
    }
  }
}
