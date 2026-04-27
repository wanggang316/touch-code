import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct HierarchyClientTests {
  private func makeLiveClient() -> (HierarchyClient, HierarchyManager) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    return (HierarchyClient.live(manager: manager), manager)
  }

  @Test
  func liveSelectWorktreeUpdatesCatalog() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, "w2", "/tmp/w2", "main")

    try client.selectWorktree(worktreeID, projectID)
    #expect(manager.catalog.projects[0].selectedWorktreeID == worktreeID)

    try client.selectWorktree(nil, projectID)
    #expect(manager.catalog.projects[0].selectedWorktreeID == nil)
  }

  @Test
  func kindReturnsGitRepoWhenProjectHasGitRoot() throws {
    let (client, _) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp/p", "/tmp/p")
    #expect(client.kind(projectID) == .gitRepo)
  }

  @Test
  func kindReturnsPlainDirWhenGitRootNil() throws {
    let (client, _) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp/p", nil)
    #expect(client.kind(projectID) == .plainDir)
  }

  @Test
  func kindReturnsNilForUnknownProject() {
    let (client, _) = makeLiveClient()
    #expect(client.kind(ProjectID()) == nil)
  }

  @Test
  func liveSetWorktreeGitViewerVisibleTogglesCatalog() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, "w", "/tmp/w", "main")

    // Default is false.
    #expect(manager.catalog.projects[0].worktrees[0].gitViewerVisible == false)

    client.setWorktreeGitViewerVisible(worktreeID, true)
    #expect(manager.catalog.projects[0].worktrees[0].gitViewerVisible == true)

    client.setWorktreeGitViewerVisible(worktreeID, false)
    #expect(manager.catalog.projects[0].worktrees[0].gitViewerVisible == false)

    // Unknown worktreeID is a silent no-op; nothing should crash, state unchanged.
    client.setWorktreeGitViewerVisible(WorktreeID(), true)
    #expect(manager.catalog.projects[0].worktrees[0].gitViewerVisible == false)
  }

  @Test
  func selectionChangesPopulatesProjectAndWorktreeOnSelect() async throws {
    let (client, _) = makeLiveClient()
    // Seed the catalog synchronously BEFORE subscribing so the stream's
    // first emission already reflects the selection chain.
    let projectID = client.addProject("p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, "w", "/tmp/w", "main")

    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()

    #expect(initial?.projectID == projectID)
    #expect(initial?.worktreeID == worktreeID)
  }

  // HierarchyClient no longer exposes per-Project editor / worktree-dir writers. Those
  // values live in `Settings.projects[pid]` (v3 schema) and tests for that storage live
  // in `SettingsStoreTests` / `SettingsWriter` coverage inside each consumer feature.

  @Test
  func liveReorderWorktreesForwardsToManager() throws {
    // Wires the closure all the way to `HierarchyManager.reorderWorktrees`.
    // Algorithm coverage lives in `HierarchyManagerReorderTests`; this test
    // only proves the closure is hooked up.
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    _ = try client.createWorktree(projectID, "main", "/repo", "main")
    let p1 = try client.createWorktree(projectID, "p1", "/repo/p1", "p1")
    manager.setWorktreePinned(worktreeID: p1, isPinned: true)
    let p2 = try client.createWorktree(projectID, "p2", "/repo/p2", "p2")
    manager.setWorktreePinned(worktreeID: p2, isPinned: true)

    try client.reorderWorktrees(projectID, .pinned, IndexSet(integer: 0), 2)
    let pinned = manager.catalog.projects[0].worktrees
      .filter { $0.isPinned }
      .map { $0.id }
    #expect(pinned == [p2, p1])
  }
}
