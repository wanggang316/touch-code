import Foundation
import Observation
import TouchCodeCore

enum HierarchyError: Error, Equatable, Sendable {
  case notFound(String)
  case invariantViolation(String)
}

@MainActor
@Observable
final class HierarchyManager {
  private(set) var catalog: Catalog
  private let store: CatalogStore
  private let runtime: HierarchyRuntime

  init(catalog: Catalog, store: CatalogStore, runtime: HierarchyRuntime) {
    self.catalog = catalog
    self.store = store
    self.runtime = runtime
  }

  // MARK: - Space mutations

  func createSpace(name: String) -> SpaceID {
    let spaceID = SpaceID()
    let space = Space(id: spaceID, name: name, projects: [], selectedProjectID: nil)
    catalog.spaces.append(space)
    catalog.selectedSpaceID = spaceID
    store.scheduleSave(catalog)
    return spaceID
  }

  func renameSpace(_ id: SpaceID, name: String) throws {
    guard let index = catalog.spaces.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Space \(id)")
    }
    catalog.spaces[index].name = name
    store.scheduleSave(catalog)
  }

  func removeSpace(_ id: SpaceID) throws {
    guard let index = catalog.spaces.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Space \(id)")
    }
    catalog.spaces.remove(at: index)
    if catalog.selectedSpaceID == id {
      catalog.selectedSpaceID = catalog.spaces.first?.id
    }
    store.scheduleSave(catalog)
  }

  // MARK: - Project mutations

  func addProject(to spaceID: SpaceID, name: String, rootPath: String) throws -> ProjectID {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
      throw HierarchyError.notFound("Space \(spaceID)")
    }

    let projectID = ProjectID()
    let project = Project(
      id: projectID,
      name: name,
      rootPath: rootPath,
      gitRoot: nil,
      worktreesDirectory: nil,
      defaultEditor: nil,
      worktrees: [],
      selectedWorktreeID: nil
    )
    catalog.spaces[spaceIndex].projects.append(project)
    catalog.spaces[spaceIndex].selectedProjectID = projectID
    store.scheduleSave(catalog)
    return projectID
  }

  func removeProject(_ id: ProjectID, from spaceID: SpaceID) throws {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
      throw HierarchyError.notFound("Space \(spaceID)")
    }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }

    catalog.spaces[spaceIndex].projects.remove(at: projectIndex)
    if catalog.spaces[spaceIndex].selectedProjectID == id {
      catalog.spaces[spaceIndex].selectedProjectID = catalog.spaces[spaceIndex].projects.first?.id
    }
    store.scheduleSave(catalog)
  }

  // MARK: - Worktree mutations

  func createWorktree(
    in projectID: ProjectID,
    in spaceID: SpaceID,
    name: String,
    path: String,
    branch: String?
  ) throws -> WorktreeID {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }

    let worktreeID = WorktreeID()
    let worktree = Worktree(
      id: worktreeID,
      name: name,
      path: path,
      branch: branch,
      tabs: [],
      selectedTabID: nil
    )
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees.append(worktree)
    catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID = worktreeID
    store.scheduleSave(catalog)
    return worktreeID
  }

  func removeWorktree(
    _ id: WorktreeID,
    from projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    guard let worktreeIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Worktree \(id)")
    }

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    for panel in worktree.tabs.flatMap({ $0.panels }) {
      runtime.closeSurface(for: panel.id)
    }

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees.remove(at: worktreeIndex)
    if catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID == id {
      catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID =
        catalog.spaces[spaceIndex].projects[projectIndex].worktrees.first?.id
    }
    store.scheduleSave(catalog)
  }

  // MARK: - Tab mutations

  func createTab(
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    name: String?
  ) throws -> TabID {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    let tabID = TabID()
    let tab = Tab(id: tabID, name: name, splitTree: SplitTree(), panels: [])
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.append(tab)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID = tabID
    store.scheduleSave(catalog)
    return tabID
  }

  func closeTab(
    _ id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Tab \(id)")
    }

    let tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    for panel in tab.panels {
      runtime.closeSurface(for: panel.id)
    }

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.remove(at: tabIndex)
    if catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID == id {
      catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID =
        catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.first?.id
    }
    store.scheduleSave(catalog)
  }

  // MARK: - Panel mutations

  func openPanel(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    workingDirectory: String,
    initialCommand: String?
  ) throws -> PanelID {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    let panelID = PanelID()
    let panel = Panel(id: panelID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    if tab.splitTree.isEmpty {
      tab.splitTree = SplitTree(leaf: panelID)
    } else {
      let leaves = tab.splitTree.leaves()
      guard let anchor = leaves.first else {
        throw HierarchyError.invariantViolation("Tab has split tree but no leaves")
      }
      tab.splitTree = try tab.splitTree.inserting(panelID, at: anchor, direction: .right)
    }

    tab.panels.append(panel)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: panel, in: worktree)

    store.scheduleSave(catalog)
    return panelID
  }

  func splitPanel(
    _ panelID: PanelID,
    direction: SplitTree<PanelID>.NewDirection,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    workingDirectory: String,
    initialCommand: String?
  ) throws -> PanelID {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    let newPanelID = PanelID()
    let newPanel = Panel(id: newPanelID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    tab.splitTree = try tab.splitTree.inserting(newPanelID, at: panelID, direction: direction)
    tab.panels.append(newPanel)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: newPanel, in: worktree)

    store.scheduleSave(catalog)
    return newPanelID
  }

  func closePanel(
    _ panelID: PanelID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    guard let panelIndex = tab.panels.firstIndex(where: { $0.id == panelID }) else {
      throw HierarchyError.notFound("Panel \(panelID)")
    }

    runtime.closeSurface(for: panelID)

    tab.panels.remove(at: panelIndex)
    tab.splitTree = tab.splitTree.removing(panelID)

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    store.scheduleSave(catalog)
  }

  func focusPanel(
    _ panelID: PanelID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    guard tab.panels.contains(where: { $0.id == panelID }) else {
      throw HierarchyError.notFound("Panel \(panelID)")
    }

    tab.splitTree = tab.splitTree.settingZoomed(panelID)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  func unfocusPanel(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    tab.splitTree = tab.splitTree.settingZoomed(nil)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  func resizeSplit(
    at path: SplitTree<PanelID>.Path,
    ratio: Double,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
      worktreeID: worktreeID,
      projectID: projectID,
      spaceID: spaceID
    ) else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID }) else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    tab.splitTree = try tab.splitTree.resizing(at: path, ratio: ratio)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  // MARK: - Helpers

  private func findProjectIndices(projectID: ProjectID, spaceID: SpaceID) -> (Int, Int)? {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == projectID }) else { return nil }
    return (spaceIndex, projectIndex)
  }

  private func findWorktreeIndices(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID
  ) -> (Int, Int, Int)? {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == projectID }) else { return nil }
    guard let worktreeIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees.firstIndex(where: { $0.id == worktreeID }) else { return nil }
    return (spaceIndex, projectIndex, worktreeIndex)
  }
}
