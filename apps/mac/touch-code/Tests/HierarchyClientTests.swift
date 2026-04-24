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
  func liveCreateSpaceMutatesManager() {
    let (client, manager) = makeLiveClient()
    let id = client.createSpace("work")
    #expect(manager.catalog.spaces.count == 1)
    #expect(manager.catalog.spaces[0].id == id)
    #expect(manager.catalog.spaces[0].name == "work")
    #expect(manager.catalog.selectedSpaceID == id)
  }

  @Test
  func liveSelectWorktreeUpdatesCatalog() throws {
    let (client, manager) = makeLiveClient()
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, spaceID, "w2", "/tmp/w2", "main")

    try client.selectWorktree(worktreeID, projectID, spaceID)
    #expect(manager.catalog.spaces[0].projects[0].selectedWorktreeID == worktreeID)

    try client.selectWorktree(nil, projectID, spaceID)
    #expect(manager.catalog.spaces[0].projects[0].selectedWorktreeID == nil)
  }

  @Test
  func kindReturnsGitRepoWhenProjectHasGitRoot() throws {
    let (client, _) = makeLiveClient()
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp/p", "/tmp/p")
    #expect(client.kind(projectID) == .gitRepo)
  }

  @Test
  func kindReturnsPlainDirWhenGitRootNil() throws {
    let (client, _) = makeLiveClient()
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp/p", nil)
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
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, spaceID, "w", "/tmp/w", "main")

    // Default is false.
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)

    client.setWorktreeGitViewerVisible(worktreeID, true)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == true)

    client.setWorktreeGitViewerVisible(worktreeID, false)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)

    // Unknown worktreeID is a silent no-op; nothing should crash, state unchanged.
    client.setWorktreeGitViewerVisible(WorktreeID(), true)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)
  }

  @Test
  func selectionChangesEmitsInitialAndOnMutation() async throws {
    let (client, _) = makeLiveClient()
    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()

    // First emission is the current (empty) selection snapshot.
    let initial = await iterator.next()
    #expect(initial == HierarchySelection(spaceID: nil, projectID: nil, worktreeID: nil))

    // Mutate: create a Space (which auto-selects it). Stream should emit.
    let spaceID = client.createSpace("work")
    let next = await iterator.next()
    #expect(next?.spaceID == spaceID)
  }

  @Test
  func selectionChangesDedupesIdenticalSelectSpace() async {
    let (client, _) = makeLiveClient()
    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()

    // Initial empty emission.
    _ = await iterator.next()

    let spaceID = client.createSpace("s")
    let afterCreate = await iterator.next()
    #expect(afterCreate?.spaceID == spaceID)

    // Two identical selects to the same Space — should yield at most one
    // further value (the second is a no-op against dedupe).
    client.selectSpace(spaceID)
    client.selectSpace(spaceID)
    client.selectSpace(nil)
    let afterNil = await iterator.next()
    #expect(afterNil?.spaceID == nil)
  }

  @Test
  func selectionChangesPopulatesAllThreeLevelsOnWorktreeSelect() async throws {
    let (client, _) = makeLiveClient()
    // Seed the catalog synchronously BEFORE subscribing so the stream's
    // first emission already reflects all three levels. Simplifies the
    // iterator loop — no need to count intermediate dedupes.
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, spaceID, "w", "/tmp/w", "main")

    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()

    #expect(initial?.spaceID == spaceID)
    #expect(initial?.projectID == projectID)
    #expect(initial?.worktreeID == worktreeID)
  }

  // MARK: - Settings Repository panes (T4) — projectID-only repository closures

  @Test
  func setRepositoryDefaultEditorSetsAndClearsAcrossSpaces() throws {
    let (client, manager) = makeLiveClient()
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp", "/tmp")

    try client.setRepositoryDefaultEditor(projectID, "vscode")
    #expect(manager.catalog.spaces[0].projects[0].defaultEditor == "vscode")

    try client.setRepositoryDefaultEditor(projectID, nil)
    #expect(manager.catalog.spaces[0].projects[0].defaultEditor == nil)
  }

  @Test
  func setRepositoryDefaultEditorThrowsForUnknownProject() throws {
    let (client, _) = makeLiveClient()
    let bogusProject = ProjectID()
    #expect(throws: (any Error).self) {
      try client.setRepositoryDefaultEditor(bogusProject, "vscode")
    }
  }

  @Test
  func setRepositoryWorktreeBaseDirectorySetsAndClearsAcrossSpaces() throws {
    let (client, manager) = makeLiveClient()
    let spaceID = client.createSpace("s")
    let projectID = try client.addProject(spaceID, "p", "/tmp", "/tmp")

    try client.setRepositoryWorktreeBaseDirectory(projectID, "/Users/me/worktrees")
    #expect(manager.catalog.spaces[0].projects[0].worktreesDirectory == "/Users/me/worktrees")

    try client.setRepositoryWorktreeBaseDirectory(projectID, nil)
    #expect(manager.catalog.spaces[0].projects[0].worktreesDirectory == nil)
  }

  @Test
  func setRepositoryWorktreeBaseDirectoryThrowsForUnknownProject() throws {
    let (client, _) = makeLiveClient()
    let bogusProject = ProjectID()
    #expect(throws: (any Error).self) {
      try client.setRepositoryWorktreeBaseDirectory(bogusProject, "/some/path")
    }
  }

  @Test
  func repositoryClosuresResolveProjectAcrossMultipleSpaces() throws {
    let (client, manager) = makeLiveClient()
    let spaceA = client.createSpace("A")
    let spaceB = client.createSpace("B")
    _ = try client.addProject(spaceA, "a1", "/tmp/a1", "/tmp/a1")
    let projectInB = try client.addProject(spaceB, "b1", "/tmp/b1", "/tmp/b1")

    try client.setRepositoryDefaultEditor(projectInB, "xcode")
    let bIdx = manager.catalog.spaces.firstIndex(where: { $0.id == spaceB })!
    #expect(manager.catalog.spaces[bIdx].projects[0].defaultEditor == "xcode")

    try client.setRepositoryWorktreeBaseDirectory(projectInB, "/tmp/wts/b1")
    #expect(manager.catalog.spaces[bIdx].projects[0].worktreesDirectory == "/tmp/wts/b1")
  }
}
