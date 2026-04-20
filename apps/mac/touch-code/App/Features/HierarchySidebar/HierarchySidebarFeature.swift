import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Sidebar reducer for the Space → Project → Worktree hierarchy. Holds
/// local view state (which Spaces / Projects have their disclosure group
/// expanded) and dispatches selection + creation commands through
/// `HierarchyClient`. Structural data is NOT in state — `HierarchySidebarView`
/// reads `HierarchyManager.catalog` from the SwiftUI environment directly,
/// matching the state-ownership trade-off recorded in the design doc.
@Reducer
struct HierarchySidebarFeature {
  @ObservableState
  struct State: Equatable {
    var expandedSpaceIDs: Set<SpaceID> = []
    var expandedProjectIDs: Set<ProjectID> = []
  }

  enum Action: Equatable {
    case spaceRowTapped(SpaceID)
    case projectRowTapped(ProjectID, inSpace: SpaceID)
    case worktreeRowTapped(WorktreeID, inProject: ProjectID, inSpace: SpaceID)
    case toggleSpaceExpansion(SpaceID)
    case toggleProjectExpansion(ProjectID)
    /// Invoked by the parent reducer when the catalog mutation stream
    /// fires — prunes stale IDs that no longer exist in the catalog.
    case pruneExpansionSets(currentSpaceIDs: Set<SpaceID>, currentProjectIDs: Set<ProjectID>)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .spaceRowTapped(let spaceID):
        hierarchyClient.selectSpace(spaceID)
        return .none

      case .projectRowTapped(let projectID, let spaceID):
        // Closure-typed client — positional call: (id, inSpace).
        try? hierarchyClient.selectProject(projectID, spaceID)
        return .none

      case .worktreeRowTapped(let worktreeID, let projectID, let spaceID):
        // Positional: (id, inProject, inSpace).
        try? hierarchyClient.selectWorktree(worktreeID, projectID, spaceID)
        return .none

      case .toggleSpaceExpansion(let spaceID):
        if state.expandedSpaceIDs.contains(spaceID) {
          state.expandedSpaceIDs.remove(spaceID)
        } else {
          state.expandedSpaceIDs.insert(spaceID)
        }
        return .none

      case .toggleProjectExpansion(let projectID):
        if state.expandedProjectIDs.contains(projectID) {
          state.expandedProjectIDs.remove(projectID)
        } else {
          state.expandedProjectIDs.insert(projectID)
        }
        return .none

      case .pruneExpansionSets(let currentSpaceIDs, let currentProjectIDs):
        state.expandedSpaceIDs.formIntersection(currentSpaceIDs)
        state.expandedProjectIDs.formIntersection(currentProjectIDs)
        return .none
      }
    }
  }
}
