import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Covers the three new Worktree-Management-era additions on
/// `HierarchyManager`: `setWorktreeArchived`,
/// `reconcileDiscoveredWorktrees`, and `runningPaneCount`.
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
    let paneID = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    fakeRuntime.reset()
    fakeRuntime.livePaneIDs.insert(paneID)

    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)
    #expect(fakeRuntime.closeSurfaceCalls == [paneID])
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

  /// Produces `(varForm, privateForm)` — two aliased paths to the same
  /// on-disk directory, one with the `/var/folders/...` prefix (what
  /// `wt ls --json` emits) and one with the `/private/var/folders/...`
  /// prefix (what T-PROJECT's canonicalized `Project.rootPath` holds
  /// after `resolvingSymlinksInPath()`). The directory itself is real;
  /// `resolvingSymlinksInPath()` only walks symlinks for existing
  /// components, so tests that need both forms to canonicalize to the
  /// same string must go through a real on-disk path.
  private static func makeAliasedTempDir(tag: String) throws -> (varForm: String, privateForm: String, url: URL) {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appending(
      path: "touch-code-wt-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // `temporaryDirectory.path` is already in `/var/folders/...` form on
    // macOS (symlink prefix). The `/private/...` alias is a simple
    // string prefix transform.
    let varForm = dir.path
    let privateForm =
      varForm.hasPrefix("/private")
      ? varForm
      : "/private" + varForm
    return (varForm, privateForm, dir)
  }

  @Test
  func reconcileDedupesSymlinkAliases() throws {
    // On macOS `/var` is a symlink to `/private/var`; T-PROJECT's
    // Project.rootPath goes through resolvingSymlinksInPath() and ends
    // up in the `/private/var/...` form, while `wt ls --json` emits
    // the unresolved `/var/...` form. Reconcile must canonicalize
    // both sides so the main checkout doesn't duplicate.
    let alias = try Self.makeAliasedTempDir(tag: "reconcile")
    defer { try? FileManager.default.removeItem(at: alias.url) }

    let spaceID = manager.createSpace(name: "s")
    // Catalog stores the resolved form, matching T-PROJECT's side.
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: alias.privateForm, gitRoot: alias.privateForm
    )
    _ = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main",
      path: alias.privateForm, branch: "main"
    )
    // Reconcile feeds the un-resolved form (what `wt ls --json` would
    // produce for a repo discovered under /var).
    let appended = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      inSpace: spaceID,
      entries: [(path: alias.varForm, branch: "main")]
    )
    #expect(appended == 0)
    #expect(manager.catalog.spaces[0].projects[0].worktrees.count == 1)
  }

  @Test
  func createWorktreeStoresCanonicalizedPath() throws {
    // PR #31 review M2: Worktree.path must land in the catalog in the
    // canonical form that HierarchyManager.canonicalPath produces, so
    // view-layer direct string comparisons against the also-canonical
    // Project.rootPath (main-checkout guard etc.) stay correct under
    // symlink aliases like /var ↔ /private/var.
    //
    // The canonical form depends on the OS's symlink table (on some
    // macOS configs resolvingSymlinksInPath collapses to /var/..., on
    // others to /private/var/...); the test asserts the invariant
    // `stored == canonicalPath(input)` for BOTH input aliases rather
    // than hardcoding which side wins.
    let alias = try Self.makeAliasedTempDir(tag: "createwt")
    defer { try? FileManager.default.removeItem(at: alias.url) }
    let canonicalForm = HierarchyManager.canonicalPath(alias.varForm)
    #expect(canonicalForm == HierarchyManager.canonicalPath(alias.privateForm))

    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: canonicalForm, gitRoot: canonicalForm
    )
    // Feeding the `/var/...` alias must still store the canonical form.
    let wtIDFromVar = try manager.createWorktree(
      in: projectID, in: spaceID, name: "from-var",
      path: alias.varForm, branch: "from-var"
    )
    let storedFromVar = manager.catalog.spaces[0].projects[0].worktrees
      .first(where: { $0.id == wtIDFromVar })?.path
    #expect(storedFromVar == canonicalForm)

    // Feeding the `/private/var/...` alias stores the same canonical.
    let wtIDFromPrivate = try manager.createWorktree(
      in: projectID, in: spaceID, name: "from-private",
      path: alias.privateForm, branch: "from-private"
    )
    let storedFromPrivate = manager.catalog.spaces[0].projects[0].worktrees
      .first(where: { $0.id == wtIDFromPrivate })?.path
    #expect(storedFromPrivate == canonicalForm)
  }

  @Test
  func canonicalPathResolvesSymlinksForExistingPaths() throws {
    // resolvingSymlinksInPath() follows symlinks for existing path
    // components. Both aliases of the same on-disk temp dir must
    // collapse to identical canonical strings.
    let alias = try Self.makeAliasedTempDir(tag: "canonical")
    defer { try? FileManager.default.removeItem(at: alias.url) }

    let canonicalVar = HierarchyManager.canonicalPath(alias.varForm)
    let canonicalPrivate = HierarchyManager.canonicalPath(alias.privateForm)
    #expect(canonicalVar == canonicalPrivate)
    // Idempotent: re-canonicalizing is a no-op.
    #expect(HierarchyManager.canonicalPath(canonicalVar) == canonicalVar)
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

  // MARK: - runningPaneCount

  @Test
  func runningPaneCountReflectsRuntime() throws {
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
    let paneA = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    let paneB = try manager.splitPane(
      paneA, direction: .right,
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    // Only paneA is live.
    fakeRuntime.livePaneIDs = [paneA]
    #expect(manager.runningPaneCount(worktreeID: worktreeID) == 1)
    // Both live.
    fakeRuntime.livePaneIDs = [paneA, paneB]
    #expect(manager.runningPaneCount(worktreeID: worktreeID) == 2)
    // None live.
    fakeRuntime.livePaneIDs = []
    #expect(manager.runningPaneCount(worktreeID: worktreeID) == 0)
  }

  @Test
  func runningPaneCountUnknownIDIsZero() {
    let unknown = WorktreeID()
    #expect(manager.runningPaneCount(worktreeID: unknown) == 0)
  }
}
