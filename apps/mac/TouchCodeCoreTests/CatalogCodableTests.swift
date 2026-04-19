import Foundation
import Testing

@testable import TouchCodeCore

struct CatalogCodableTests {
  @Test
  func emptyCatalogRoundTrip() throws {
    let catalog = Catalog()
    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
    #expect(decoded.version == Catalog.currentVersion)
  }

  @Test
  func populatedCatalogRoundTrip() throws {
    let panel = Panel(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])
    let worktree = Worktree(
      name: "main", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id
    )
    let space = Space(name: "work", projects: [project], selectedProjectID: project.id)
    let window = CatalogWindow(selectedSpaceID: space.id)
    let catalog = Catalog(
      windows: [window],
      spaces: [space],
      selectedSpaceID: space.id
    )

    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
  }

  @Test
  func decodingRejectsUnknownVersion() throws {
    let payload = Data(#"{"version": 99, "windows": [], "spaces": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  @Test
  func decodingTolerantOfMissingOptionalFields() throws {
    let payload = Data(#"{"version": 1}"#.utf8)
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.windows.isEmpty)
    #expect(catalog.spaces.isEmpty)
    #expect(catalog.selectedSpaceID == nil)
  }

  @Test
  func tabInvariantsHoldForSeededTab() throws {
    let a = Panel(workingDirectory: "/a")
    let b = Panel(workingDirectory: "/b")
    let tree = try SplitTree(leaf: a.id).inserting(b.id, at: a.id, direction: .right)
    let tab = Tab(splitTree: tree, panels: [a, b])
    try tab.validateInvariants()
  }

  @Test
  func tabInvariantsFailWhenPanelsDriftFromTree() throws {
    let a = Panel(workingDirectory: "/a")
    let b = Panel(workingDirectory: "/b")
    let extraPanel = Panel(workingDirectory: "/c")
    let tree = try SplitTree(leaf: a.id).inserting(b.id, at: a.id, direction: .right)
    let badTab = Tab(splitTree: tree, panels: [a, b, extraPanel])
    #expect(throws: Tab.InvariantError.self) {
      try badTab.validateInvariants()
    }
  }

  @Test
  func tabInvariantsFailOnDuplicatePanelIDs() throws {
    let a = Panel(workingDirectory: "/a")
    let tab = Tab(splitTree: SplitTree(leaf: a.id), panels: [a, a])
    #expect(throws: Tab.InvariantError.duplicatePanelIDs) {
      try tab.validateInvariants()
    }
  }
}
