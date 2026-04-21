import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Coverage for `WorktreeDetailFeature`'s composition: actions dispatched
/// against the child scopes must route via `tabBar` / `splitViewport`
/// without any additional behaviour on the parent reducer itself.
@MainActor
struct WorktreeDetailFeatureTests {
  @Test
  func tabBarActionRoutesViaScope() async {
    let received = LockIsolated<TabID?>(nil)
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let spaceID = SpaceID()
    let newTabID = TabID()

    let store = TestStore(initialState: WorktreeDetailFeature.State()) {
      WorktreeDetailFeature()
    } withDependencies: {
      $0.hierarchyClient.createTab = { _, _, _, _ in
        received.withValue { $0 = newTabID }
        return newTabID
      }
    }

    await store.send(
      .tabBar(
        .newTabButtonTapped(
          inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
        )))
    #expect(received.value == newTabID)
  }

  @Test
  func splitViewportActionRoutesViaScope() async {
    let tabID = TabID()
    let store = TestStore(initialState: WorktreeDetailFeature.State()) {
      WorktreeDetailFeature()
    }
    await store.send(.splitViewport(.activeTabChanged(tabID))) { state in
      state.splitViewport.activeTabID = tabID
    }
  }
}
