import Foundation
import Testing

@testable import TouchCodeCore

/// Exercises `Catalog.init(from:)` / `Catalog.encode(to:)` for the v3
/// schema (Tags + flat Projects + activeTagFilter; no Space, no
/// CatalogWindow), plus the v2→v3 and chained v1→v2→v3 migrations.
struct CatalogCodableTests {
  @Test
  func emptyCatalogRoundTrip() throws {
    let catalog = Catalog()
    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
    #expect(decoded.version == Catalog.currentVersion)
    #expect(decoded.activeTagFilter == .all)
  }

  @Test
  func populatedCatalogRoundTrip() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id
    )
    let tag = Tag(name: "client-acme", color: .blue)
    let project = Project(
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id,
      tagIDs: [tag.id]
    )
    let catalog = Catalog(
      projects: [project],
      tags: [tag],
      activeTagFilter: .tags([tag.id])
    )

    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
  }

  @Test
  func decodingRejectsUnknownVersion() throws {
    let payload = Data(#"{"version": 99, "projects": [], "tags": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  @Test
  func decodingTolerantOfMissingOptionalFields() throws {
    let payload = Data(#"{"version": 3}"#.utf8)
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.projects.isEmpty)
    #expect(catalog.tags.isEmpty)
    #expect(catalog.activeTagFilter == .all)
  }

  @Test
  func encodeOmitsActiveTagFilterWhenAll() throws {
    // Symmetric with isPinned/gitViewerVisible/isExpanded: omit the key
    // when the value is the decode-time default. Pre-tag catalogs decode
    // to `.all` so writes back stay byte-identical when the filter is
    // unset.
    let catalog = Catalog()
    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["activeTagFilter"] == nil)
  }

  @Test
  func encodeIncludesActiveTagFilterWhenNonDefault() throws {
    let tag = Tag(name: "urgent", color: .red)
    let catalog = Catalog(tags: [tag], activeTagFilter: .tags([tag.id]))
    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["activeTagFilter"] != nil)
  }

  // MARK: - v2 -> v3 migration

  @Test
  func migrationV2ToV3ProducesOneTagPerSpace() throws {
    let payload = try v2Payload(spaces: [
      ("Day Job", []),
      ("Side", []),
    ])
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.version == 3)
    #expect(catalog.tags.count == 2)
    #expect(catalog.tags[0].name == "Day Job")
    #expect(catalog.tags[1].name == "Side")
    #expect(catalog.tags[0].color == .blue)    // palette[0]
    #expect(catalog.tags[1].color == .orange)  // palette[1]
  }

  @Test
  func migrationV2ToV3AssignsEachProjectItsSpaceTag() throws {
    let projectA: [String: Any] = ["id": ["raw": UUID().uuidString], "name": "acme-web", "rootPath": "/tmp/acme"]
    let projectB: [String: Any] = ["id": ["raw": UUID().uuidString], "name": "marketing", "rootPath": "/tmp/mkt"]
    let payload = try v2Payload(spaces: [
      ("Day Job", [projectA]),
      ("Side", [projectB]),
    ])
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.projects.count == 2)
    let acme = try #require(catalog.projects.first { $0.name == "acme-web" })
    let mkt = try #require(catalog.projects.first { $0.name == "marketing" })
    let dayJobTag = try #require(catalog.tags.first { $0.name == "Day Job" })
    let sideTag = try #require(catalog.tags.first { $0.name == "Side" })
    #expect(acme.tagIDs == [dayJobTag.id])
    #expect(mkt.tagIDs == [sideTag.id])
  }

  @Test
  func migrationV2ToV3UsesSelectedSpaceIDForInitialFilter() throws {
    let spaceAID = UUID()
    let spaceBID = UUID()
    let payload = try v2PayloadRaw(
      spaces: [
        ["id": ["raw": spaceAID.uuidString], "name": "Day Job", "projects": []],
        ["id": ["raw": spaceBID.uuidString], "name": "Side", "projects": []],
      ],
      windows: [],
      selectedSpaceID: ["raw": spaceBID.uuidString]
    )
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    let sideTag = try #require(catalog.tags.first { $0.name == "Side" })
    #expect(catalog.activeTagFilter == .tags([sideTag.id]))
  }

  @Test
  func migrationV2ToV3FallsBackToFirstWindowFilter() throws {
    let spaceAID = UUID()
    let spaceBID = UUID()
    let payload = try v2PayloadRaw(
      spaces: [
        ["id": ["raw": spaceAID.uuidString], "name": "Day Job", "projects": []],
        ["id": ["raw": spaceBID.uuidString], "name": "Side", "projects": []],
      ],
      windows: [
        ["id": UUID().uuidString, "selectedSpaceID": ["raw": spaceBID.uuidString]],
      ],
      selectedSpaceID: nil
    )
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    let sideTag = try #require(catalog.tags.first { $0.name == "Side" })
    #expect(catalog.activeTagFilter == .tags([sideTag.id]))
  }

  @Test
  func migrationV2ToV3WithEmptySpacesYieldsAllFilter() throws {
    let payload = try v2PayloadRaw(spaces: [], windows: [], selectedSpaceID: nil)
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.tags.isEmpty)
    #expect(catalog.projects.isEmpty)
    #expect(catalog.activeTagFilter == .all)
  }

  @Test
  func migrationV2ToV3PaletteCyclesAfterSeven() throws {
    // 8 spaces → palette wraps. The 8th tag's color must equal the 1st's.
    let names = (1...8).map { ("Space\($0)", [[String: Any]]()) }
    let payload = try v2Payload(spaces: names)
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.tags.count == 8)
    #expect(catalog.tags[7].color == catalog.tags[0].color)
  }

  // MARK: - Worktree default-omission round-trips (preserved from v2 era)

  @Test
  func encodeOmitsGitViewerVisibleWhenFalse() throws {
    let worktree = Worktree(name: "w", path: "/w")
    let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
    let catalog = Catalog(projects: [project])

    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(root["projects"] as? [[String: Any]])
    let firstProject = try #require(projects.first)
    let worktrees = try #require(firstProject["worktrees"] as? [[String: Any]])
    let firstWorktree = try #require(worktrees.first)
    #expect(firstWorktree["gitViewerVisible"] == nil)

    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
  }

  // MARK: - Tab invariants (preserved verbatim from v2 era)

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

  // MARK: - v2 payload helpers

  /// Build a minimal v2 catalog JSON from name+projects pairs. Spaces are
  /// assigned fresh UUIDs.
  private func v2Payload(spaces: [(String, [[String: Any]])]) throws -> Data {
    let spaceDicts: [[String: Any]] = spaces.map { (name, projects) in
      [
        "id": ["raw": UUID().uuidString],
        "name": name,
        "projects": projects,
      ]
    }
    return try v2PayloadRaw(spaces: spaceDicts, windows: [], selectedSpaceID: nil)
  }

  /// Build a v2 catalog JSON from raw dicts. Use this when the test needs
  /// to control space IDs / window selection precisely.
  private func v2PayloadRaw(
    spaces: [[String: Any]],
    windows: [[String: Any]],
    selectedSpaceID: [String: Any]?
  ) throws -> Data {
    var root: [String: Any] = [
      "version": 2,
      "spaces": spaces,
      "windows": windows,
    ]
    if let selectedSpaceID {
      root["selectedSpaceID"] = selectedSpaceID
    }
    return try JSONSerialization.data(withJSONObject: root)
  }
}
