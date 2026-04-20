import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Tab bar reducer. State-free controller: Worktree.tabs is read from the
/// environment `HierarchyManager` at render time; actions dispatch create /
/// select / close commands through `HierarchyClient`. Errors are swallowed
/// (logged only) — tab-bar failures are rare and not worth modal UX today.
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
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .newTabButtonTapped(let worktreeID, let projectID, let spaceID):
        _ = try? hierarchyClient.createTab(worktreeID, projectID, spaceID, nil)
        return .none

      case .tabButtonTapped(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.selectTab(tabID, worktreeID, projectID, spaceID)
        return .none

      case .closeButtonTapped(let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID, spaceID)
        return .none
      }
    }
  }
}
