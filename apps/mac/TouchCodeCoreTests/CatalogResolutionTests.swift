import Foundation
import Testing

@testable import TouchCodeCore

struct CatalogResolutionTests {
  @Test
  func worktreeIDForPanelFindsAcrossTabs() throws {
    let panelA = Panel(workingDirectory: "/a")
    let panelB = Panel(workingDirectory: "/b")
    let panelC = Panel(workingDirectory: "/c")

    let tab1 = Tab(splitTree: SplitTree(leaf: panelA.id), panels: [panelA])
    let tab2 = Tab(
      splitTree: try SplitTree(leaf: panelB.id).inserting(panelC.id, at: panelB.id, direction: .right),
      panels: [panelB, panelC]
    )
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab1, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let space = Space(name: "s", projects: [project])
    let catalog = Catalog(spaces: [space])

    #expect(catalog.worktreeID(forPanel: panelA.id) == worktree.id)
    #expect(catalog.worktreeID(forPanel: panelB.id) == worktree.id)
    #expect(catalog.worktreeID(forPanel: panelC.id) == worktree.id)
  }

  @Test
  func worktreeIDForPanelMissingReturnsNil() {
    let catalog = Catalog(spaces: [
      Space(name: "s", projects: [
        Project(name: "p", rootPath: "/p", worktrees: [
          Worktree(name: "w", path: "/p"),
        ]),
      ]),
    ])
    #expect(catalog.worktreeID(forPanel: PanelID()) == nil)
  }

  @Test
  func panelIDsInWorktreeReturnsAllLeaves() throws {
    let panelA = Panel(workingDirectory: "/a")
    let panelB = Panel(workingDirectory: "/b")
    let panelC = Panel(workingDirectory: "/c")
    let panelD = Panel(workingDirectory: "/d")

    let tab1 = Tab(
      splitTree: try SplitTree(leaf: panelA.id).inserting(panelB.id, at: panelA.id, direction: .right),
      panels: [panelA, panelB]
    )
    let tab2 = Tab(
      splitTree: try SplitTree(leaf: panelC.id).inserting(panelD.id, at: panelC.id, direction: .down),
      panels: [panelC, panelD]
    )
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab1, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(spaces: [Space(name: "s", projects: [project])])

    #expect(catalog.panelIDs(inWorktree: worktree.id) == Set([panelA.id, panelB.id, panelC.id, panelD.id]))
  }

  @Test
  func panelIDsInWorktreeUnknownReturnsEmpty() {
    let catalog = Catalog()
    #expect(catalog.panelIDs(inWorktree: WorktreeID()).isEmpty)
  }
}
