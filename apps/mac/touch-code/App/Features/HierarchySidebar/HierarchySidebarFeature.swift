import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Returns the smallest-index unused "Untitled Space [N]" name given the
/// current list of Spaces. Treats bare "Untitled Space" as the N=1 slot;
/// the first new Space gets bare, the second gets "Untitled Space 2", and
/// so on, filling holes before extending the tail.
///
/// Pure. No disk I/O, no MainActor. Exposed to tests via `@testable import`.
/// File-scope (not method on the reducer) so the reducer stays focused on
/// action→effect mapping and the test target can call it without touching
/// TCA machinery.
func nextUntitledSpaceName(in spaces: [Space]) -> String {
  let bare = "Untitled Space"
  var occupied: Set<Int> = []
  for space in spaces {
    if space.name == bare {
      occupied.insert(1)
      continue
    }
    guard space.name.hasPrefix(bare + " ") else { continue }
    let suffix = space.name.dropFirst(bare.count + 1)
    // Reject leading zeros, signs, whitespace — only a clean positive integer counts.
    guard !suffix.isEmpty,
          suffix.allSatisfy(\.isNumber),
          suffix.first != "0",
          let n = Int(suffix),
          n > 0
    else { continue }
    occupied.insert(n)
  }
  var candidate = 1
  while occupied.contains(candidate) { candidate += 1 }
  return candidate == 1 ? bare : "\(bare) \(candidate)"
}

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
