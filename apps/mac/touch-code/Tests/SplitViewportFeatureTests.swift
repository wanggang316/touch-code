import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct SplitViewportFeatureTests {
  @Test
  func activeTabChangedUpdatesState() async {
    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    }
    let tabID = TabID()
    await store.send(.activeTabChanged(tabID)) {
      $0.activeTabID = tabID
    }
    await store.send(.activeTabChanged(nil)) {
      $0.activeTabID = nil
    }
  }

  @Test
  func newPanelForwardsToOpenPanel() async {
    let received = LockIsolated<(TabID, WorktreeID, ProjectID, SpaceID, String)?>(nil)
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let spaceID = SpaceID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.openPanel = { tid, wid, pid, sid, cwd, _ in
        received.withValue { $0 = (tid, wid, pid, sid, cwd) }
        return PanelID()
      }
    }

    await store.send(
      .newPanelButtonTapped(
        inTab: tabID, inWorktree: worktreeID,
        inProject: projectID, inSpace: spaceID,
        workingDirectory: "/tmp/x"
      ))
    let captured = received.value
    #expect(captured?.0 == tabID)
    #expect(captured?.1 == worktreeID)
    #expect(captured?.4 == "/tmp/x")
  }

  @Test
  func splitForwardsToSplitPanel() async {
    let received = LockIsolated<(PanelID, SplitTree<PanelID>.NewDirection)?>(nil)
    let panelID = PanelID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.splitPanel = { pid, dir, _, _, _, _, _, _ in
        received.withValue { $0 = (pid, dir) }
        return PanelID()
      }
    }

    await store.send(
      .splitButtonTapped(
        panelID, direction: .right,
        inTab: TabID(), inWorktree: WorktreeID(),
        inProject: ProjectID(), inSpace: SpaceID(),
        workingDirectory: "/"
      ))
    #expect(received.value?.0 == panelID)
    #expect(received.value?.1 == .right)
  }

  @Test
  func closePanelForwardsToClosePanel() async {
    let received = LockIsolated<PanelID?>(nil)
    let panelID = PanelID()

    let store = TestStore(initialState: SplitViewportFeature.State()) {
      SplitViewportFeature()
    } withDependencies: {
      $0.hierarchyClient.closePanel = { pid, _, _, _, _ in
        received.withValue { $0 = pid }
      }
    }

    await store.send(
      .closePanelButtonTapped(
        panelID, inTab: TabID(), inWorktree: WorktreeID(),
        inProject: ProjectID(), inSpace: SpaceID()
      ))
    #expect(received.value == panelID)
  }
}
