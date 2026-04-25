import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Forwarding contract: the `env` argument passed to
/// `HierarchyManager.openPane` and `splitPane` reaches the runtime's
/// `ensureSurface` call unchanged. FakeHierarchyRuntime records the env on
/// every call so we can assert the exact map made it across.
@MainActor
struct HierarchyManagerOpenPaneEnvForwardTests {
  private func makeManager() -> (HierarchyManager, FakeHierarchyRuntime) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    return (manager, runtime)
  }

  private func setupTab(_ manager: HierarchyManager) throws -> (
    SpaceID, ProjectID, WorktreeID, TabID
  ) {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(
      to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, in: spaceID, name: nil
    )
    return (spaceID, projectID, worktreeID, tabID)
  }

  @Test
  func openPaneForwardsEnvToRuntime() throws {
    let (manager, runtime) = makeManager()
    let (spaceID, projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: ["A": "1", "B": "2"]
    )

    #expect(runtime.ensureSurfaceCalls.count == 1)
    #expect(runtime.ensureSurfaceCalls[0].env == ["A": "1", "B": "2"])
  }

  @Test
  func openPaneDefaultEnvIsEmpty() throws {
    let (manager, runtime) = makeManager()
    let (spaceID, projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    #expect(runtime.ensureSurfaceCalls.count == 1)
    #expect(runtime.ensureSurfaceCalls[0].env.isEmpty)
  }

  @Test
  func splitPaneForwardsEnvToRuntime() throws {
    let (manager, runtime) = makeManager()
    let (spaceID, projectID, worktreeID, tabID) = try setupTab(manager)
    let firstPaneID = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    _ = try manager.splitPane(
      firstPaneID,
      direction: .right,
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: ["SPLIT_VAR": "42"]
    )

    #expect(runtime.ensureSurfaceCalls.count == 2)
    #expect(runtime.ensureSurfaceCalls[1].env == ["SPLIT_VAR": "42"])
  }

  @Test
  func openPaneEmptyEnvProducesEmptyRecordedEnv() throws {
    let (manager, runtime) = makeManager()
    let (spaceID, projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: [:]
    )

    #expect(runtime.ensureSurfaceCalls[0].env.isEmpty)
  }
}
