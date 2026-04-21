import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct TabBarFeatureTests {
  @Test
  func newTabButtonCallsCreateTab() async {
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let spaceID = SpaceID()
    let received = LockIsolated<(WorktreeID, ProjectID, SpaceID, String?)?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.createTab = { w, p, s, name in
        received.withValue { $0 = (w, p, s, name) }
        return TabID()
      }
    }

    await store.send(
      .newTabButtonTapped(
        inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
      ))
    let captured = received.value
    #expect(captured?.0 == worktreeID)
    #expect(captured?.1 == projectID)
    #expect(captured?.2 == spaceID)
    #expect(captured?.3 == nil)
  }

  @Test
  func tabButtonCallsSelectTab() async {
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let spaceID = SpaceID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectTab = { id, _, _, _ in
        received.withValue { $0 = id }
      }
    }

    await store.send(
      .tabButtonTapped(
        tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
      ))
    #expect(received.value == tabID)
  }

  @Test
  func closeButtonCallsCloseTab() async {
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let spaceID = SpaceID()
    let received = LockIsolated<TabID?>(nil)

    let store = TestStore(initialState: TabBarFeature.State()) {
      TabBarFeature()
    } withDependencies: {
      $0.hierarchyClient.closeTab = { id, _, _, _ in
        received.withValue { $0 = id }
      }
    }

    await store.send(
      .closeButtonTapped(
        tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
      ))
    #expect(received.value == tabID)
  }
}
