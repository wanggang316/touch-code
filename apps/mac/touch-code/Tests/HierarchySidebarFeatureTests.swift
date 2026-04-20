import ComposableArchitecture
import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

@MainActor
struct HierarchySidebarFeatureTests {
  @Test
  func toggleSpaceExpansionFlipsSet() async {
    let spaceID = SpaceID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }

    await store.send(.toggleSpaceExpansion(spaceID)) {
      $0.expandedSpaceIDs.insert(spaceID)
    }
    await store.send(.toggleSpaceExpansion(spaceID)) {
      $0.expandedSpaceIDs.remove(spaceID)
    }
  }

  @Test
  func toggleProjectExpansionFlipsSet() async {
    let projectID = ProjectID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }

    await store.send(.toggleProjectExpansion(projectID)) {
      $0.expandedProjectIDs.insert(projectID)
    }
    await store.send(.toggleProjectExpansion(projectID)) {
      $0.expandedProjectIDs.remove(projectID)
    }
  }

  @Test
  func worktreeRowTappedForwardsToHierarchyClient() async {
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let received = LockIsolated<(WorktreeID, ProjectID, SpaceID)?>(nil)

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectWorktree = { id, project, space in
        received.withValue { $0 = (id ?? WorktreeID(), project, space) }
      }
    }

    await store.send(.worktreeRowTapped(worktreeID, inProject: projectID, inSpace: spaceID))
    let captured = received.value
    #expect(captured?.0 == worktreeID)
    #expect(captured?.1 == projectID)
    #expect(captured?.2 == spaceID)
  }

  @Test
  func pruneExpansionSetsDropsStaleIDs() async {
    let live = SpaceID()
    let stale = SpaceID()
    let staleProject = ProjectID()
    let liveProject = ProjectID()

    let initial = HierarchySidebarFeature.State(
      expandedSpaceIDs: [live, stale],
      expandedProjectIDs: [liveProject, staleProject]
    )
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    }

    await store.send(
      .pruneExpansionSets(
        currentSpaceIDs: [live],
        currentProjectIDs: [liveProject]
      )
    ) {
      $0.expandedSpaceIDs = [live]
      $0.expandedProjectIDs = [liveProject]
    }
  }
}
