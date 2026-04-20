import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

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
}
