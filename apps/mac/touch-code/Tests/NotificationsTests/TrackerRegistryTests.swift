import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct TrackerRegistryTests {
  @Test
  func bootstrapCreatesTrackerForEveryAgentLabelledPanel() {
    let catalog = Self.catalog(panels: [
      Self.panel(labels: ["agent:claude"]),
      Self.panel(labels: []),
      Self.panel(labels: ["agent:aider", "misc"]),
    ])
    let registry = TrackerRegistry(
      hierarchy: Self.hierarchy(catalog: catalog),
      idleThreshold: 120
    )
    registry.bootstrap()
    #expect(registry.allTrackers.count == 2)
  }

  @Test
  func createIsIdempotent() {
    let registry = Self.emptyRegistry()
    let id = PanelID()
    let first = registry.create(for: id)
    let second = registry.create(for: id)
    #expect(first === second)
    #expect(registry.allTrackers.count == 1)
  }

  @Test
  func destroyRemovesTracker() {
    let registry = Self.emptyRegistry()
    let id = PanelID()
    _ = registry.create(for: id)
    #expect(registry.tracker(for: id) != nil)
    registry.destroy(for: id)
    #expect(registry.tracker(for: id) == nil)
  }

  @Test
  func trackerForNilReturnsNil() {
    let registry = Self.emptyRegistry()
    #expect(registry.tracker(for: nil) == nil)
  }

  @Test
  func trackerCreationsStreamEmitsOnCreate() async {
    let registry = Self.emptyRegistry()
    var iterator = registry.trackerCreations.makeAsyncIterator()
    let id = PanelID()
    _ = registry.create(for: id)
    let yielded = await iterator.next()
    #expect(yielded == id)
  }

  @Test
  func agentLabelledPanelsStaticWalksFullHierarchy() {
    let panelA = Self.panel(labels: ["agent:claude"])
    let panelB = Self.panel(labels: [])
    let panelC = Self.panel(labels: ["agent:codex"])
    let catalog = Self.catalog(panels: [panelA, panelB, panelC])
    let found = TrackerRegistry.agentLabelledPanels(in: catalog)
    #expect(Set(found.map(\.id)) == [panelA.id, panelC.id])
  }

  // MARK: - Helpers

  private static func emptyRegistry() -> TrackerRegistry {
    TrackerRegistry(
      hierarchy: Self.hierarchy(catalog: Self.catalog(panels: [])),
      idleThreshold: 120
    )
  }

  private static func panel(labels: Set<String>) -> Panel {
    Panel(
      workingDirectory: "/tmp",
      initialCommand: nil,
      labels: labels
    )
  }

  private static func catalog(panels: [Panel]) -> Catalog {
    let tab = Tab(
      splitTree: panels.first.map { SplitTree(leaf: $0.id) } ?? SplitTree(leaf: PanelID()),
      panels: panels
    )
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id)
    let project = Project(
      name: "p",
      rootPath: "/p",
      gitRoot: "/p",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id
    )
    let space = Space(name: "s", projects: [project], selectedProjectID: project.id)
    return Catalog(
      version: Catalog.currentVersion,
      windows: [],
      spaces: [space],
      selectedSpaceID: space.id
    )
  }

  private static func hierarchy(catalog: Catalog) -> HierarchyManager {
    let fakeRuntime = FakeHierarchyRuntime()
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    let store = CatalogStore(fileURL: tempURL)
    return HierarchyManager(catalog: catalog, store: store, runtime: fakeRuntime)
  }
}
