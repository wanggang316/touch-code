import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Coverage for the worktree-sidebar-ordering catalog primitives:
/// - `HierarchyManager.reorderWorktrees(in:inSpace:segment:from:to:)`
/// - `HierarchyManager.createWorktree`'s unpinned-segment-top insertion
/// - `HierarchyManager.setWorktreePinned`'s boundary-aware repositioning
///
/// See `docs/design-docs/worktree-sidebar-ordering.md` and
/// `docs/exec-plans/worktree-reorder-catalog.md` for the contract.
@MainActor
struct HierarchyManagerReorderTests {
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

  // MARK: - createWorktree insertion

  @Test
  func createWorktreeLandsAtUnpinnedSegmentTop() throws {
    // Setup: main + 2 pinned + 3 unpinned. With the new insertion rule,
    // each newly created unpinned worktree appears at the segment top, so
    // the resulting catalog is [main, p1, p2, u3, u2, u1] with the most
    // recently created unpinned row sitting right after the pinned section.
    let (sid, pid) = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let u1 = try manager.createWorktree(in: pid, in: sid, name: "u1", path: "/repo/u1", branch: "u1")
    let u2 = try manager.createWorktree(in: pid, in: sid, name: "u2", path: "/repo/u2", branch: "u2")
    let u3 = try manager.createWorktree(in: pid, in: sid, name: "u3", path: "/repo/u3", branch: "u3")
    let beforeIDs = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    let mainID = beforeIDs[0]
    #expect(beforeIDs == [mainID, p1, p2, u3, u2, u1])

    // Create a fourth unpinned. It must land at the unpinned-segment top —
    // catalog index 3 (right after the last pinned), pushing u3 down.
    let u4 = try manager.createWorktree(in: pid, in: sid, name: "u4", path: "/repo/u4", branch: "u4")
    let after = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    #expect(after == [mainID, p1, p2, u4, u3, u2, u1])
    #expect(after[3] == u4)
  }

  @Test
  func createWorktreeFirstUnpinnedRowLandsAfterMain() throws {
    // No pinned, no archived: boundary equals worktrees.count, so the new
    // row appears at the array tail (index 1). View order: [main, w1].
    let (sid, pid) = try makeProject()
    let w1 = try manager.createWorktree(in: pid, in: sid, name: "w1", path: "/repo/w1", branch: "w1")
    let ids = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    #expect(ids.count == 2)
    #expect(ids[1] == w1)
  }

  @Test
  func createWorktreeSkipsPastArchivedRows() throws {
    // Archived rows do not shift the boundary backward — they are not
    // visible in any segment, so a new unpinned row must come AFTER them
    // in the catalog so the view still shows it as the first unpinned.
    let (sid, pid) = try makeProject()
    let archived = try manager.createWorktree(
      in: pid, in: sid, name: "old", path: "/repo/old", branch: "old"
    )
    try manager.setWorktreeArchived(worktreeID: archived, archived: true)
    let beforeCount = manager.catalog.spaces[0].projects[0].worktrees.count
    #expect(beforeCount == 2)

    let fresh = try manager.createWorktree(in: pid, in: sid, name: "new", path: "/repo/new", branch: "new")
    let ids = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    #expect(ids.count == 3)
    #expect(ids[2] == fresh)
  }

  // MARK: - setWorktreePinned positioning

  @Test
  func pinMovesRowToPinnedSegmentEnd() throws {
    let (sid, pid) = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    // Catalog: [main, p1, p2]. Now create u1, then pin it — it should
    // land at the END of the pinned segment (after p2).
    let u1 = try manager.createWorktree(in: pid, in: sid, name: "u1", path: "/repo/u1", branch: "u1")
    manager.setWorktreePinned(worktreeID: u1, isPinned: true)
    let ids = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    let mainID = ids[0]
    #expect(ids == [mainID, p1, p2, u1])
    let pinnedSegment = pinnedView(in: pid)
    #expect(pinnedSegment == [p1, p2, u1])
  }

  @Test
  func pinIdempotentDoesNotReposition() throws {
    let (sid, pid) = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let snapshot = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    // No flag flip ⇒ no reorder. The idempotency guard preserves the
    // existing pinned-segment order so back-to-back Pin clicks do not
    // shuffle the section.
    manager.setWorktreePinned(worktreeID: p1, isPinned: true)
    manager.setWorktreePinned(worktreeID: p2, isPinned: true)
    let after = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    #expect(after == snapshot)
  }

  @Test
  func unpinMovesRowToUnpinnedSegmentTop() throws {
    let (sid, pid) = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let u1 = try manager.createWorktree(in: pid, in: sid, name: "u1", path: "/repo/u1", branch: "u1")
    let u2 = try manager.createWorktree(in: pid, in: sid, name: "u2", path: "/repo/u2", branch: "u2")
    // Catalog now: [main, p1, p2, u2, u1]. Unpinned segment view: [u2, u1].

    // Unpin p2: flag flips, then row moves to the boundary, which lands
    // it at the top of the unpinned segment in the view.
    manager.setWorktreePinned(worktreeID: p2, isPinned: false)
    let unpinned = unpinnedView(in: pid)
    #expect(unpinned.first == p2)
    #expect(unpinned == [p2, u2, u1])
    // p1 remains the only pinned row.
    #expect(pinnedView(in: pid) == [p1])
  }

  @Test
  func unpinAlreadyUnpinnedIsNoOp() throws {
    let (sid, pid) = try makeProject()
    let u1 = try manager.createWorktree(in: pid, in: sid, name: "u1", path: "/repo/u1", branch: "u1")
    let snapshot = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    manager.setWorktreePinned(worktreeID: u1, isPinned: false)
    let after = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    #expect(after == snapshot)
  }

  // MARK: - reorderWorktrees

  @Test
  func reorderPinnedSegmentMovesWithinSection() throws {
    let (sid, pid) = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let p3 = try makePinned(name: "p3", path: "/repo/p3", in: pid, sid: sid)
    let u1 = try manager.createWorktree(in: pid, in: sid, name: "u1", path: "/repo/u1", branch: "u1")
    // Pinned segment view: [p1, p2, p3]. Move segment-relative idx 0 to 3
    // (SwiftUI ForEach.onMove convention: dragging the first row past the
    // last row).
    try manager.reorderWorktrees(
      in: pid, inSpace: sid, segment: .pinned,
      from: IndexSet(integer: 0), to: 3
    )
    #expect(pinnedView(in: pid) == [p2, p3, p1])
    // Other segments untouched.
    #expect(unpinnedView(in: pid) == [u1])
  }

  @Test
  func reorderUnpinnedSegmentMovesWithinSection() throws {
    let (sid, pid) = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let u1 = try manager.createWorktree(in: pid, in: sid, name: "u1", path: "/repo/u1", branch: "u1")
    let u2 = try manager.createWorktree(in: pid, in: sid, name: "u2", path: "/repo/u2", branch: "u2")
    let u3 = try manager.createWorktree(in: pid, in: sid, name: "u3", path: "/repo/u3", branch: "u3")
    // Unpinned segment view: [u3, u2, u1]. Move segment-relative idx 2 to
    // 0 (drag the last row to the top).
    try manager.reorderWorktrees(
      in: pid, inSpace: sid, segment: .unpinned,
      from: IndexSet(integer: 2), to: 0
    )
    #expect(unpinnedView(in: pid) == [u1, u3, u2])
  }

  @Test
  func reorderOutOfRangeFromIsNoOp() throws {
    let (sid, pid) = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    _ = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let snapshot = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    try manager.reorderWorktrees(
      in: pid, inSpace: sid, segment: .pinned,
      from: IndexSet(integer: 5), to: 0
    )
    #expect(manager.catalog.spaces[0].projects[0].worktrees.map { $0.id } == snapshot)
  }

  @Test
  func reorderOutOfRangeToIsNoOp() throws {
    let (sid, pid) = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    _ = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let snapshot = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    try manager.reorderWorktrees(
      in: pid, inSpace: sid, segment: .pinned,
      from: IndexSet(integer: 0), to: 99
    )
    #expect(manager.catalog.spaces[0].projects[0].worktrees.map { $0.id } == snapshot)
  }

  @Test
  func reorderEmptyIndexSetIsNoOp() throws {
    let (sid, pid) = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let snapshot = manager.catalog.spaces[0].projects[0].worktrees.map { $0.id }
    try manager.reorderWorktrees(
      in: pid, inSpace: sid, segment: .pinned,
      from: IndexSet(), to: 0
    )
    #expect(manager.catalog.spaces[0].projects[0].worktrees.map { $0.id } == snapshot)
  }

  @Test
  func reorderUnknownProjectThrows() throws {
    let (sid, _) = try makeProject()
    let bogus = ProjectID()
    #expect(throws: HierarchyError.self) {
      try manager.reorderWorktrees(
        in: bogus, inSpace: sid, segment: .pinned,
        from: IndexSet(integer: 0), to: 0
      )
    }
  }

  @Test
  func reorderDoesNotDisturbArchivedRows() throws {
    // Archived rows live in the catalog but not in any segment; reorder
    // must rewrite only segment indices and leave archived rows in place.
    let (sid, pid) = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid, sid: sid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid, sid: sid)
    let archived = try manager.createWorktree(
      in: pid, in: sid, name: "old", path: "/repo/old", branch: "old"
    )
    try manager.setWorktreeArchived(worktreeID: archived, archived: true)
    let beforeArchivedIdx = manager.catalog.spaces[0].projects[0]
      .worktrees.firstIndex { $0.id == archived }
    try manager.reorderWorktrees(
      in: pid, inSpace: sid, segment: .pinned,
      from: IndexSet(integer: 0), to: 2
    )
    let afterArchivedIdx = manager.catalog.spaces[0].projects[0]
      .worktrees.firstIndex { $0.id == archived }
    #expect(beforeArchivedIdx == afterArchivedIdx)
    #expect(pinnedView(in: pid) == [p2, p1])
  }

  // MARK: - Helpers

  private func makeProject() throws -> (SpaceID, ProjectID) {
    let sid = manager.createSpace(name: "s")
    let pid = try manager.addProject(
      to: sid, name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: pid, in: sid, name: "main", path: "/repo", branch: "main"
    )
    return (sid, pid)
  }

  private func makePinned(
    name: String, path: String, in pid: ProjectID, sid: SpaceID
  ) throws -> WorktreeID {
    let id = try manager.createWorktree(
      in: pid, in: sid, name: name, path: path, branch: name
    )
    manager.setWorktreePinned(worktreeID: id, isPinned: true)
    return id
  }

  private func pinnedView(in pid: ProjectID) -> [WorktreeID] {
    let project = manager.catalog.spaces[0].projects.first { $0.id == pid }!
    let root = project.rootPath
    return project.worktrees
      .filter { !$0.archived && $0.isPinned && $0.path != root }
      .map { $0.id }
  }

  private func unpinnedView(in pid: ProjectID) -> [WorktreeID] {
    let project = manager.catalog.spaces[0].projects.first { $0.id == pid }!
    let root = project.rootPath
    return project.worktrees
      .filter { !$0.archived && !$0.isPinned && $0.path != root }
      .map { $0.id }
  }
}
