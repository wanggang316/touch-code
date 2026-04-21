import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

/// Covers the three new Worktree-Management-era additions on
/// `HierarchyManager`: `setWorktreeArchived`,
/// `reconcileDiscoveredWorktrees`, and `runningPanelCount`.
///
/// Each test builds a fresh manager + fake runtime per `init`, matching
/// the pattern in `HierarchyManagerTests.swift`.
@MainActor
struct HierarchyManagerWorktreeMgmtTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  // MARK: - setWorktreeArchived

  @Test
  func archiveTogglesFlag() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)
    let worktree = manager.catalog.spaces[0].projects[0].worktrees.first { $0.id == worktreeID }
    #expect(worktree?.archived == true)
  }

  @Test
  func archiveIsIdempotent() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: false)
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: false)
    let worktree = manager.catalog.spaces[0].projects[0].worktrees.first { $0.id == worktreeID }
    #expect(worktree?.archived == false)
  }

  @Test
  func archiveMainCheckoutThrows() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    // addProject with gitRoot != nil does not synthesize a worktree;
    // create one whose path EQUALS the Project rootPath to simulate the
    // main checkout discovered by reconcile.
    let mainID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    #expect(throws: HierarchyError.self) {
      try manager.setWorktreeArchived(worktreeID: mainID, archived: true)
    }
  }

  @Test
  func archiveTearsDownSurfaces() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, in: spaceID, name: nil
    )
    let panelID = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    fakeRuntime.reset()
    fakeRuntime.livePanelIDs.insert(panelID)

    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)
    #expect(fakeRuntime.closeSurfaceCalls == [panelID])
  }

  // MARK: - reconcileDiscoveredWorktrees

  @Test
  func reconcileAppendsUnknownEntries() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    let appended = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      inSpace: spaceID,
      entries: [
        (path: "/repo", branch: "main"),
        (path: "/repo/feature", branch: "feature"),
      ]
    )
    #expect(appended == 1)
    #expect(manager.catalog.spaces[0].projects[0].worktrees.count == 2)
  }

  @Test
  func reconcileIsIdempotent() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let entries: [(path: String, branch: String?)] = [
      (path: "/repo", branch: "main"),
      (path: "/repo/feature", branch: "feature"),
    ]
    let first = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, inSpace: spaceID, entries: entries
    )
    let second = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, inSpace: spaceID, entries: entries
    )
    #expect(first == 2)
    #expect(second == 0)
    #expect(manager.catalog.spaces[0].projects[0].worktrees.count == 2)
  }

  @Test
  func reconcileNeverDeletesExistingRows() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    _ = try manager.createWorktree(
      in: projectID, in: spaceID, name: "stale", path: "/repo/stale", branch: "stale"
    )
    // `stale` is no longer in the on-disk entries — reconcile must
    // still keep it in the catalog (only user-invoked Prune deletes).
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      inSpace: spaceID,
      entries: [(path: "/repo", branch: "main")]
    )
    #expect(manager.catalog.spaces[0].projects[0].worktrees.count == 2)
  }

  // MARK: - runningPanelCount

  @Test
  func runningPanelCountReflectsRuntime() throws {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, in: spaceID, name: nil
    )
    let panelA = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    let panelB = try manager.splitPanel(
      panelA, direction: .right,
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    // Only panelA is live.
    fakeRuntime.livePanelIDs = [panelA]
    #expect(manager.runningPanelCount(worktreeID: worktreeID) == 1)
    // Both live.
    fakeRuntime.livePanelIDs = [panelA, panelB]
    #expect(manager.runningPanelCount(worktreeID: worktreeID) == 2)
    // None live.
    fakeRuntime.livePanelIDs = []
    #expect(manager.runningPanelCount(worktreeID: worktreeID) == 0)
  }

  @Test
  func runningPanelCountUnknownIDIsZero() {
    let unknown = WorktreeID()
    #expect(manager.runningPanelCount(worktreeID: unknown) == 0)
  }
}
