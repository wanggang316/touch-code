import Foundation
import Testing

@testable import TouchCodeCore

/// Pane.labels is an additive field (exec-plan 0003 M1). Existing v1
/// catalog files must decode successfully with an empty labels set; newly
/// written catalogs must round-trip labels.
struct PaneLabelsCatalogTests {
  @Test
  func defaultConstructorYieldsEmptyLabels() {
    let pane = Pane(workingDirectory: "/tmp")
    #expect(pane.labels.isEmpty)
  }

  @Test
  func paneRoundTripsLabels() throws {
    let pane = Pane(
      workingDirectory: "/tmp",
      labels: ["agent", "claude"]
    )
    let data = try JSONEncoder().encode(pane)
    let decoded = try JSONDecoder().decode(Pane.self, from: data)
    #expect(decoded == pane)
    #expect(decoded.labels == Set(["agent", "claude"]))
  }

  @Test
  func legacyPaneWithoutLabelsFieldStillDecodes() throws {
    // A pre-labels v1 pane JSON blob — simulates a user's existing
    // catalog.json that predates the additive field. PaneID's Codable
    // synthesises `{"raw": "<uuid>"}` from the wrapped `let raw: UUID`.
    let uuid = UUID()
    let legacy = Data(#"{"id":{"raw":"\#(uuid.uuidString)"},"workingDirectory":"/tmp"}"#.utf8)
    let decoded = try JSONDecoder().decode(Pane.self, from: legacy)
    #expect(decoded.labels.isEmpty)
    #expect(decoded.workingDirectory == "/tmp")
    #expect(decoded.id.raw == uuid)
  }

  @Test
  func paneWithoutLabelsOmitsFieldOnEncode() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let data = try JSONEncoder().encode(pane)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("labels"))
  }

  @Test
  func fullCatalogRoundTripsLabelsEndToEnd() throws {
    let pane = Pane(workingDirectory: "/tmp", labels: ["agent"])
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id)
    let project = Project(
      name: "touch-code", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let space = Space(name: "work", projects: [project], selectedProjectID: project.id)
    let catalog = Catalog(spaces: [space], selectedSpaceID: space.id)

    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)

    let roundTripped = decoded.spaces[0].projects[0].worktrees[0].tabs[0].panes[0]
    #expect(roundTripped.labels == Set(["agent"]))
  }
}
