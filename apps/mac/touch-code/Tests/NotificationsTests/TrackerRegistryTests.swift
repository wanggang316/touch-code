import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct TrackerRegistryTests {
  @Test
  func bootstrapCreatesTrackerForEveryAgentLabelledPane() {
    let catalog = Self.catalog(panes: [
      Self.pane(labels: ["agent:claude"]),
      Self.pane(labels: []),
      Self.pane(labels: ["agent:aider", "misc"]),
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
    let id = PaneID()
    let first = registry.create(for: id)
    let second = registry.create(for: id)
    #expect(first === second)
    #expect(registry.allTrackers.count == 1)
  }

  @Test
  func destroyRemovesTracker() {
    let registry = Self.emptyRegistry()
    let id = PaneID()
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
    let id = PaneID()
    _ = registry.create(for: id)
    let yielded = await iterator.next()
    #expect(yielded == id)
  }

  @Test
  func agentLabelledPanesStaticWalksFullHierarchy() {
    let paneA = Self.pane(labels: ["agent:claude"])
    let paneB = Self.pane(labels: [])
    let paneC = Self.pane(labels: ["agent:codex"])
    let catalog = Self.catalog(panes: [paneA, paneB, paneC])
    let found = TrackerRegistry.agentLabelledPanes(in: catalog)
    #expect(Set(found.map(\.id)) == [paneA.id, paneC.id])
  }

  // MARK: - Helpers

  private static func emptyRegistry() -> TrackerRegistry {
    TrackerRegistry(
      hierarchy: Self.hierarchy(catalog: Self.catalog(panes: [])),
      idleThreshold: 120
    )
  }

  private static func pane(labels: Set<String>) -> Pane {
    Pane(
      workingDirectory: "/tmp",
      initialCommand: nil,
      labels: labels
    )
  }

  private static func catalog(panes: [Pane]) -> Catalog {
    let tab = Tab(
      splitTree: panes.first.map { SplitTree(leaf: $0.id) } ?? SplitTree(leaf: PaneID()),
      panes: panes
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
