import Foundation
import Testing

@testable import TouchCodeCore

struct CatalogResolutionTests {
  @Test
  func worktreeIDForPaneFindsAcrossTabs() throws {
    let paneA = Pane(workingDirectory: "/a")
    let paneB = Pane(workingDirectory: "/b")
    let paneC = Pane(workingDirectory: "/c")

    let tab1 = Tab(splitTree: SplitTree(leaf: paneA.id), panes: [paneA])
    let tab2 = Tab(
      splitTree: try SplitTree(leaf: paneB.id).inserting(paneC.id, at: paneB.id, direction: .right),
      panes: [paneB, paneC]
    )
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab1, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let space = Space(name: "s", projects: [project])
    let catalog = Catalog(spaces: [space])

    #expect(catalog.worktreeID(forPane: paneA.id) == worktree.id)
    #expect(catalog.worktreeID(forPane: paneB.id) == worktree.id)
    #expect(catalog.worktreeID(forPane: paneC.id) == worktree.id)
  }

  @Test
  func worktreeIDForPaneMissingReturnsNil() {
    let catalog = Catalog(spaces: [
      Space(name: "s", projects: [
        Project(name: "p", rootPath: "/p", worktrees: [
          Worktree(name: "w", path: "/p"),
        ]),
      ]),
    ])
    #expect(catalog.worktreeID(forPane: PaneID()) == nil)
  }

  @Test
  func paneIDsInWorktreeReturnsAllLeaves() throws {
    let paneA = Pane(workingDirectory: "/a")
    let paneB = Pane(workingDirectory: "/b")
    let paneC = Pane(workingDirectory: "/c")
    let paneD = Pane(workingDirectory: "/d")

    let tab1 = Tab(
      splitTree: try SplitTree(leaf: paneA.id).inserting(paneB.id, at: paneA.id, direction: .right),
      panes: [paneA, paneB]
    )
    let tab2 = Tab(
      splitTree: try SplitTree(leaf: paneC.id).inserting(paneD.id, at: paneC.id, direction: .down),
      panes: [paneC, paneD]
    )
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab1, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(spaces: [Space(name: "s", projects: [project])])

    #expect(catalog.paneIDs(inWorktree: worktree.id) == Set([paneA.id, paneB.id, paneC.id, paneD.id]))
  }

  @Test
  func paneIDsInWorktreeUnknownReturnsEmpty() {
    let catalog = Catalog()
    #expect(catalog.paneIDs(inWorktree: WorktreeID()).isEmpty)
  }
}
