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
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
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
  func decodesPreT0JSONWithDefaults() throws {
    // Encode a pre-T0 shaped catalog — a Space without `lastActiveWorktreeID`
    // and a Worktree without `gitViewerVisible` — by building the JSON
    // structure explicitly, then strip those keys. Defaults must apply on
    // decode without throwing.
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
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
    let catalog = Catalog(spaces: [space], selectedSpaceID: space.id)

    let encoded = try JSONEncoder().encode(catalog)
    var root = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    root["spaces"] = (root["spaces"] as? [[String: Any]]).map { spaces in
      spaces.map { spaceDict -> [String: Any] in
        var space = spaceDict
        space.removeValue(forKey: "lastActiveWorktreeID")
        space["projects"] = (space["projects"] as? [[String: Any]]).map { projects in
          projects.map { projectDict -> [String: Any] in
            var project = projectDict
            project["worktrees"] = (project["worktrees"] as? [[String: Any]]).map { worktrees in
              worktrees.map { worktreeDict -> [String: Any] in
                var worktree = worktreeDict
                worktree.removeValue(forKey: "gitViewerVisible")
                return worktree
              }
            } ?? []
            return project
          }
        } ?? []
        return space
      }
    } ?? []
    let stripped = try JSONSerialization.data(withJSONObject: root)

    let decoded = try JSONDecoder().decode(Catalog.self, from: stripped)
    let decodedSpace = try #require(decoded.spaces.first)
    #expect(decodedSpace.lastActiveWorktreeID == nil)
    let decodedProject = try #require(decodedSpace.projects.first)
    let decodedWorktree = try #require(decodedProject.worktrees.first)
    #expect(decodedWorktree.gitViewerVisible == false)
  }

  @Test
  func roundTripsLastActiveWorktreeAndGitViewerVisible() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main",
      path: "/repo",
      branch: "main",
      tabs: [tab],
      selectedTabID: tab.id,
      gitViewerVisible: true
    )
    let project = Project(
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id
    )
    let space = Space(
      name: "work",
      projects: [project],
      selectedProjectID: project.id,
      lastActiveWorktreeID: worktree.id
    )
    let catalog = Catalog(spaces: [space], selectedSpaceID: space.id)

    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
    #expect(decoded.spaces.first?.lastActiveWorktreeID == worktree.id)
    #expect(decoded.spaces.first?.projects.first?.worktrees.first?.gitViewerVisible == true)
  }

  @Test
  func encodeOmitsGitViewerVisibleWhenFalse() throws {
    // Codable-symmetry fix: the default-false `gitViewerVisible` is dropped
    // from encoded output to match how `Space.lastActiveWorktreeID` uses
    // `encodeIfPresent`. Keeps on-disk catalogs lean and makes pre-T0 JSON
    // round-trip-identical on disk once re-encoded.
    let worktree = Worktree(name: "w", path: "/w") // gitViewerVisible defaults to false
    let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
    let space = Space(name: "s", projects: [project])
    let catalog = Catalog(spaces: [space])

    let data = try JSONEncoder().encode(catalog)
    let root = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let decodedSpace = try #require((root["spaces"] as? [[String: Any]])?.first)
    let decodedProject = try #require((decodedSpace["projects"] as? [[String: Any]])?.first)
    let decodedWorktree = try #require(
      (decodedProject["worktrees"] as? [[String: Any]])?.first
    )
    #expect(decodedWorktree["gitViewerVisible"] == nil)

    // Round-trip still yields the same Swift value — decoder's
    // `decodeIfPresent ?? false` fills the gap.
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
  }

  @Test
  func tabInvariantsHoldForSeededTab() throws {
    let a = Pane(workingDirectory: "/a")
    let b = Pane(workingDirectory: "/b")
    let tree = try SplitTree(leaf: a.id).inserting(b.id, at: a.id, direction: .right)
    let tab = Tab(splitTree: tree, panes: [a, b])
    try tab.validateInvariants()
  }

  @Test
  func tabInvariantsFailWhenPanesDriftFromTree() throws {
    let a = Pane(workingDirectory: "/a")
    let b = Pane(workingDirectory: "/b")
    let extraPane = Pane(workingDirectory: "/c")
    let tree = try SplitTree(leaf: a.id).inserting(b.id, at: a.id, direction: .right)
    let badTab = Tab(splitTree: tree, panes: [a, b, extraPane])
    #expect(throws: Tab.InvariantError.self) {
      try badTab.validateInvariants()
    }
  }

  @Test
  func tabInvariantsFailOnDuplicatePaneIDs() throws {
    let a = Pane(workingDirectory: "/a")
    let tab = Tab(splitTree: SplitTree(leaf: a.id), panes: [a, a])
    #expect(throws: Tab.InvariantError.duplicatePaneIDs) {
      try tab.validateInvariants()
    }
  }
}
