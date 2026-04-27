import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct HierarchySidebarFeatureTests {
  @Test
  func toggleProjectExpansionFlipsCatalogFlag() async {
    // Project expansion lives on `Project.isExpanded` (persisted) — the
    // reducer reads the current catalog value and forwards the flipped
    // value to `setProjectExpanded`. No reducer-state mutation expected.
    let projectID = ProjectID()
    let project = Project(id: projectID, name: "p", rootPath: "/p", isExpanded: true)
    let received = LockIsolated<[(ProjectID, Bool)]>([])

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = {
        Catalog(projects: [project])
      }
      $0.hierarchyClient.setProjectExpanded = { id, expanded in
        received.withValue { $0.append((id, expanded)) }
      }
    }

    await store.send(.toggleProjectExpansion(projectID))
    #expect(received.value.count == 1)
    #expect(received.value[0].0 == projectID)
    #expect(received.value[0].1 == false)
  }

  @Test
  func worktreeRevealInFinderEmitsDelegate() async {
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }
    await store.send(.worktreeRevealInFinderTapped(path: "/tmp/demo"))
    await store.receive(.delegate(.revealInFinder(path: "/tmp/demo")))
  }

  @Test
  func worktreeOpenInDefaultEditorEmitsDelegate() async {
    let projectID = ProjectID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }
    await store.send(
      .worktreeOpenInDefaultEditorTapped(
        worktreeID: WorktreeID(),
        projectID: projectID,
        path: "/tmp/demo"
      )
    )
    await store.receive(
      .delegate(.openInDefaultEditor(worktreePath: "/tmp/demo", projectID: projectID))
    )
  }
}
