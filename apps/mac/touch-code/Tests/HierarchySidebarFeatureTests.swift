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
    let received = LockIsolated<(WorktreeID?, ProjectID, SpaceID)?>(nil)

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectWorktree = { id, project, space in
        received.withValue { $0 = (id, project, space) }
      }
      // Empty snapshot → the lastActive-dedup branch finds no matching space
      // and skips the setSpaceLastActiveWorktree write.
      $0.hierarchyClient.snapshot = {
        Catalog(windows: [], spaces: [], selectedSpaceID: nil)
      }
    }

    await store.send(.worktreeRowTapped(worktreeID, inProject: projectID, inSpace: spaceID))
    let captured = received.value
    #expect(captured != nil)
    // Preserve the nil-vs-value distinction — a regression where the
    // reducer accidentally nils out the ID would now fail loudly instead
    // of silently synthesising a fresh WorktreeID.
    #expect(captured?.0 == worktreeID)
    #expect(captured?.1 == projectID)
    #expect(captured?.2 == spaceID)
  }

  // MARK: - nextUntitledSpaceName

  @Test
  func nextUntitledSpaceNameOnEmptyCatalogIsBare() async {
    #expect(nextUntitledSpaceName(in: []) == "Untitled Space")
  }

  @Test
  func nextUntitledSpaceNameWithOnlyBareReturnsTwo() async {
    let spaces = [Self.space(named: "Untitled Space")]
    #expect(nextUntitledSpaceName(in: spaces) == "Untitled Space 2")
  }

  @Test
  func nextUntitledSpaceNameFillsHoleBetweenBareAndThree() async {
    let spaces = [
      Self.space(named: "Untitled Space"),
      Self.space(named: "Untitled Space 3"),
      Self.space(named: "My Project"),
    ]
    #expect(nextUntitledSpaceName(in: spaces) == "Untitled Space 2")
  }

  @Test
  func nextUntitledSpaceNameBareWinsWhenOnlyTwoExists() async {
    let spaces = [Self.space(named: "Untitled Space 2")]
    #expect(nextUntitledSpaceName(in: spaces) == "Untitled Space")
  }

  private static func space(named name: String) -> Space {
    Space(id: SpaceID(), name: name, projects: [], selectedProjectID: nil)
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
