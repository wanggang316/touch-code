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
  func kindReturnsDirWhenGitRootNil() throws {
    let (client, _) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp/p", nil)
    #expect(client.kind(projectID) == .dir)
  }

  @Test
  func kindReturnsNilForUnknownProject() {
    let (client, _) = makeLiveClient()
    #expect(client.kind(ProjectID()) == nil)
  }

  @Test
  func liveSetWorktreeDiffInspectorVisibleTogglesCatalog() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, "w", "/tmp/w", "main")

    // Default is false.
    #expect(manager.catalog.projects[0].worktrees[0].diffInspectorVisible == false)

    client.setWorktreeDiffInspectorVisible(worktreeID, true)
    #expect(manager.catalog.projects[0].worktrees[0].diffInspectorVisible == true)

    client.setWorktreeDiffInspectorVisible(worktreeID, false)
    #expect(manager.catalog.projects[0].worktrees[0].diffInspectorVisible == false)

    // Unknown worktreeID is a silent no-op; nothing should crash, state unchanged.
    client.setWorktreeDiffInspectorVisible(WorktreeID(), true)
    #expect(manager.catalog.projects[0].worktrees[0].diffInspectorVisible == false)
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

  /// Multi-project regression: tapping a worktree in P2 must surface
  /// `(P2, W2)` even when P1 still carries a non-nil `selectedWorktreeID`
  /// (which it does after any prior selection in P1). Pre-fix the
  /// `currentSelection` resolver returned the first project in catalog
  /// order whose `selectedWorktreeID` was non-nil, pinning the answer to
  /// P1; the fix adds a top-level `Catalog.selectedProjectID` that
  /// `selectProject` writes and `currentSelection` reads first.
  @Test
  func selectionChangesRespectsLatestProjectAcrossMultipleProjects() async throws {
    let (client, _) = makeLiveClient()
    let p1 = client.addProject("p1", "/tmp/p1", "/tmp/p1")
    let w1 = try client.createWorktree(p1, "w1", "/tmp/p1/w1", "main")
    let p2 = client.addProject("p2", "/tmp/p2", "/tmp/p2")
    let w2 = try client.createWorktree(p2, "w2", "/tmp/p2/w2", "main")

    // Touch P1 first so it owns a selectedWorktreeID.
    client.selectProject(p1)
    try client.selectWorktree(w1, p1)

    // Now switch to P2.
    client.selectProject(p2)
    try client.selectWorktree(w2, p2)

    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()

    #expect(initial?.projectID == p2)
    #expect(initial?.worktreeID == w2)
  }

  @Test
  func selectProjectClearedOnRemoveProject() throws {
    let (client, manager) = makeLiveClient()
    let p = client.addProject("p", "/tmp", "/tmp")
    client.selectProject(p)
    #expect(manager.catalog.selectedProjectID == p)
    try client.removeProject(p)
    #expect(manager.catalog.selectedProjectID == nil)
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
