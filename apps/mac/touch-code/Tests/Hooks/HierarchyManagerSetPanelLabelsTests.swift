import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct HierarchyManagerSetPanelLabelsTests {
  @Test
  func replaceOverwritesExistingLabels() throws {
    let (manager, panelID) = try Self.makeManagerWithPanel(initialLabels: ["old"])
    try manager.setPanelLabels(panelID, labels: ["new"], replace: true)
    #expect(Self.readLabels(manager, panelID: panelID) == Set(["new"]))
  }

  @Test
  func mergeUnionsWithExistingLabels() throws {
    let (manager, panelID) = try Self.makeManagerWithPanel(initialLabels: ["old"])
    try manager.setPanelLabels(panelID, labels: ["new"], replace: false)
    #expect(Self.readLabels(manager, panelID: panelID) == Set(["old", "new"]))
  }

  @Test
  func unknownPanelIDThrows() throws {
    let (manager, _) = try Self.makeManagerWithPanel(initialLabels: [])
    let foreign = PanelID()
    #expect(throws: HierarchyError.self) {
      try manager.setPanelLabels(foreign, labels: ["x"])
    }
  }

  // MARK: - Helpers

  static func makeManagerWithPanel(initialLabels: Set<String>) throws -> (HierarchyManager, PanelID) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-labels-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let panel = Panel(workingDirectory: "/tmp", labels: initialLabels)
    let tab = Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])
    let worktree = Worktree(
      name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let space = Space(name: "s", projects: [project], selectedProjectID: project.id)
    let catalog = Catalog(spaces: [space], selectedSpaceID: space.id)

    let store = CatalogStore(fileURL: url)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: runtime)
    return (manager, panel.id)
  }

  static func readLabels(_ manager: HierarchyManager, panelID: PanelID) -> Set<String> {
    for space in manager.catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            if let panel = tab.panels.first(where: { $0.id == panelID }) {
              return panel.labels
            }
          }
        }
      }
    }
    return []
  }
}
