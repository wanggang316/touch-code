import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct HierarchyManagerTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  @Test
  func createWorktreeAppendsAndSetsSelected() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    #expect(manager.catalog.spaces[0].projects[0].worktrees.count == 1)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].id == worktreeID)
    #expect(manager.catalog.spaces[0].projects[0].selectedWorktreeID == worktreeID)
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
  }

  @Test
  func removeNonExistentWorktreeThrows() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")

    let fakeID = WorktreeID()
    #expect(throws: HierarchyError.self) {
      try manager.removeWorktree(fakeID, from: projectID, in: spaceID)
    }
  }

  @Test
  func createTabAppendsAndSetsSelected() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: "tab1")

    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.count == 1)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0].id == tabID)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabID)
  }

  @Test
  func openPanelInEmptyTabCreatesLeaf() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)

    let panelID = try manager.openPanel(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.panels.count == 1)
    #expect(tab.panels[0].id == panelID)
    #expect(tab.splitTree.leaves() == [panelID])
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].panelID == panelID)
  }

  @Test
  func splitPanelCreatesNewLeaf() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    fakeRuntime.reset()
    let newPanelID = try manager.splitPanel(
      panelID,
      direction: .right,
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.panels.count == 2)
    #expect(tab.splitTree.leaves().count == 2)
    #expect(tab.splitTree.contains(newPanelID))
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].panelID == newPanelID)
  }

  @Test
  func closePanelRemovesFromSplitTree() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    fakeRuntime.reset()
    try manager.closePanel(panelID, in: tabID, in: worktreeID, in: projectID, in: spaceID)

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.panels.isEmpty)
    #expect(tab.splitTree.isEmpty)
    #expect(fakeRuntime.closeSurfaceCalls == [panelID])
  }

  @Test
  func tabValidateInvariantsHoldsAfterSplit() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    _ = try manager.splitPanel(
      panelID,
      direction: .right,
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(throws: Never.self) {
      try tab.validateInvariants()
    }
  }

  @Test
  func focusPanelSetsZoom() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    try manager.focusPanel(panelID, in: tabID, in: worktreeID, in: projectID, in: spaceID)

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.splitTree.zoomed == panelID)
  }

  @Test
  func setDefaultEditorWritesPerProjectOverride() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")

    try manager.setDefaultEditor("vscode", for: projectID, in: spaceID)
    #expect(manager.catalog.spaces[0].projects[0].defaultEditor == "vscode")

    // Nil clears the override.
    try manager.setDefaultEditor(nil, for: projectID, in: spaceID)
    #expect(manager.catalog.spaces[0].projects[0].defaultEditor == nil)
  }

  @Test
  func setDefaultEditorThrowsForUnknownProject() {
    let spaceID = manager.createSpace(name: "test")
    let bogusProject = ProjectID()
    #expect(throws: (any Error).self) {
      try manager.setDefaultEditor("vscode", for: bogusProject, in: spaceID)
    }
  }

  @Test
  func setSpaceLastActiveWorktreePersists() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )

    manager.setSpaceLastActiveWorktree(spaceID: spaceID, worktreeID: worktreeID)
    #expect(manager.catalog.spaces[0].lastActiveWorktreeID == worktreeID)

    manager.setSpaceLastActiveWorktree(spaceID: spaceID, worktreeID: nil)
    #expect(manager.catalog.spaces[0].lastActiveWorktreeID == nil)
  }

  @Test
  func setSpaceLastActiveWorktreeMissingSpaceIsSilentNoOp() {
    let bogus = SpaceID()
    manager.setSpaceLastActiveWorktree(spaceID: bogus, worktreeID: WorktreeID())
    #expect(manager.catalog.spaces.isEmpty)
  }

  @Test
  func setWorktreeGitViewerVisiblePersists() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)

    manager.setWorktreeGitViewerVisible(worktreeID: worktreeID, visible: true)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == true)

    manager.setWorktreeGitViewerVisible(worktreeID: worktreeID, visible: false)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)
  }

  @Test
  func setWorktreeGitViewerVisibleMissingWorktreeIsSilentNoOp() {
    let bogus = WorktreeID()
    manager.setWorktreeGitViewerVisible(worktreeID: bogus, visible: true)
    #expect(manager.catalog.spaces.isEmpty)
  }
}
