import Foundation
import Testing

@testable import TouchCodeCore

/// Panel.labels is an additive field (exec-plan 0003 M1). Existing v1
/// catalog files must decode successfully with an empty labels set; newly
/// written catalogs must round-trip labels.
struct PanelLabelsCatalogTests {
  @Test
  func defaultConstructorYieldsEmptyLabels() {
    let panel = Panel(workingDirectory: "/tmp")
    #expect(panel.labels.isEmpty)
  }

  @Test
  func panelRoundTripsLabels() throws {
    let panel = Panel(
      workingDirectory: "/tmp",
      labels: ["agent", "claude"]
    )
    let data = try JSONEncoder().encode(panel)
    let decoded = try JSONDecoder().decode(Panel.self, from: data)
    #expect(decoded == panel)
    #expect(decoded.labels == Set(["agent", "claude"]))
  }

  @Test
  func legacyPanelWithoutLabelsFieldStillDecodes() throws {
    // A pre-labels v1 panel JSON blob — simulates a user's existing
    // catalog.json that predates the additive field. PanelID's Codable
    // synthesises `{"raw": "<uuid>"}` from the wrapped `let raw: UUID`.
    let uuid = UUID()
    let legacy = Data(#"{"id":{"raw":"\#(uuid.uuidString)"},"workingDirectory":"/tmp"}"#.utf8)
    let decoded = try JSONDecoder().decode(Panel.self, from: legacy)
    #expect(decoded.labels.isEmpty)
    #expect(decoded.workingDirectory == "/tmp")
    #expect(decoded.id.raw == uuid)
  }

  @Test
  func panelWithoutLabelsOmitsFieldOnEncode() throws {
    let panel = Panel(workingDirectory: "/tmp")
    let data = try JSONEncoder().encode(panel)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("labels"))
  }

  @Test
  func fullCatalogRoundTripsLabelsEndToEnd() throws {
    let panel = Panel(workingDirectory: "/tmp", labels: ["agent"])
    let tab = Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id)
    let project = Project(
      name: "touch-code", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let space = Space(name: "work", projects: [project], selectedProjectID: project.id)
    let catalog = Catalog(spaces: [space], selectedSpaceID: space.id)

    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)

    let roundTripped = decoded.spaces[0].projects[0].worktrees[0].tabs[0].panels[0]
    #expect(roundTripped.labels == Set(["agent"]))
  }
}
