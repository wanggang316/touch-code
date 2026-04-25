import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct HierarchyManagerTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  @Test
  func createWorktreeAppendsAndSetsSelected() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    #expect(manager.catalog.spaces[0].projects[0].worktrees.count == 1)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].id == worktreeID)
    #expect(manager.catalog.spaces[0].projects[0].selectedWorktreeID == worktreeID)
    #expect(fakeRuntime.ensureSurfaceCalls.isEmpty)
  }

  @Test
  func removeNonExistentWorktreeThrows() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")

    let fakeID = WorktreeID()
    #expect(throws: HierarchyError.self) {
      try manager.removeWorktree(fakeID, from: projectID, in: spaceID)
    }
  }

  @Test
  func createTabAppendsAndSetsSelected() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )

    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: "tab1")

    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.count == 1)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0].id == tabID)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabID)
  }

  @Test
  func openPaneInEmptyTabCreatesLeaf() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)

    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 1)
    #expect(tab.panes[0].id == paneID)
    #expect(tab.splitTree.leaves() == [paneID])
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].paneID == paneID)
  }

  @Test
  func splitPaneCreatesNewLeaf() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    fakeRuntime.reset()
    let newPaneID = try manager.splitPane(
      paneID,
      direction: .right,
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.count == 2)
    #expect(tab.splitTree.leaves().count == 2)
    #expect(tab.splitTree.contains(newPaneID))
    #expect(fakeRuntime.ensureSurfaceCalls.count == 1)
    #expect(fakeRuntime.ensureSurfaceCalls[0].paneID == newPaneID)
  }

  @Test
  func closePaneRemovesFromSplitTree() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    fakeRuntime.reset()
    try manager.closePane(paneID, in: tabID, in: worktreeID, in: projectID, in: spaceID)

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.panes.isEmpty)
    #expect(tab.splitTree.isEmpty)
    #expect(fakeRuntime.closeSurfaceCalls == [paneID])
  }

  @Test
  func tabValidateInvariantsHoldsAfterSplit() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    _ = try manager.splitPane(
      paneID,
      direction: .right,
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(throws: Never.self) {
      try tab.validateInvariants()
    }
  }

  @Test
  func focusPaneSetsZoom() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID,
      in: spaceID,
      name: "main",
      path: "/repo",
      branch: "main"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let paneID = try manager.openPane(
      in: tabID,
      in: worktreeID,
      in: projectID,
      in: spaceID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    try manager.focusPane(paneID, in: tabID, in: worktreeID, in: projectID, in: spaceID)

    let tab = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0]
    #expect(tab.splitTree.zoomed == paneID)
  }

  // Per-Project editor / worktrees-directory mutators moved off HierarchyManager in v3
  // and now live on `SettingsStore.mutateProject`; see `SettingsStoreTests` for their
  // coverage. The drain shim (`drainLegacyOverrides`) is tested below alongside
  // the v1 → v2 catalog migration.

  @Test
  func setSpaceLastActiveWorktreePersists() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )

    manager.setSpaceLastActiveWorktree(spaceID: spaceID, worktreeID: worktreeID)
    #expect(manager.catalog.spaces[0].lastActiveWorktreeID == worktreeID)

    manager.setSpaceLastActiveWorktree(spaceID: spaceID, worktreeID: nil)
    #expect(manager.catalog.spaces[0].lastActiveWorktreeID == nil)
  }

  @Test
  func setSpaceLastActiveWorktreeMissingSpaceIsSilentNoOp() {
    let bogus = SpaceID()
    manager.setSpaceLastActiveWorktree(spaceID: bogus, worktreeID: WorktreeID())
    #expect(manager.catalog.spaces.isEmpty)
  }

  @Test
  func setWorktreeGitViewerVisiblePersists() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)

    manager.setWorktreeGitViewerVisible(worktreeID: worktreeID, visible: true)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == true)

    manager.setWorktreeGitViewerVisible(worktreeID: worktreeID, visible: false)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].gitViewerVisible == false)
  }

  @Test
  func setWorktreeGitViewerVisibleMissingWorktreeIsSilentNoOp() {
    let bogus = WorktreeID()
    manager.setWorktreeGitViewerVisible(worktreeID: bogus, visible: true)
    #expect(manager.catalog.spaces.isEmpty)
  }

  // MARK: - P0.2: Project Management mutations

  @Test
  func reorderProjectsMovesInPlaceAndPersists() throws {
    let spaceID = manager.createSpace(name: "work")
    let a = try manager.addProject(to: spaceID, name: "a", rootPath: "/tmp/a")
    let b = try manager.addProject(to: spaceID, name: "b", rootPath: "/tmp/b")
    let c = try manager.addProject(to: spaceID, name: "c", rootPath: "/tmp/c")

    // Move the third entry ("c") to the front.
    try manager.reorderProjects(in: spaceID, from: IndexSet(integer: 2), to: 0)

    let order = manager.catalog.spaces[0].projects.map(\.id)
    #expect(order == [c, a, b])
  }

  @Test
  func reorderProjectsMissingSpaceThrows() {
    let bogus = SpaceID()
    #expect(throws: HierarchyError.self) {
      try manager.reorderProjects(in: bogus, from: IndexSet(integer: 0), to: 1)
    }
  }

  @Test
  func setProjectLoadStateUpdatesAndHandlesEqualValue() throws {
    let spaceID = manager.createSpace(name: "work")
    let projectID = try manager.addProject(to: spaceID, name: "p", rootPath: "/tmp/p")
    #expect(manager.catalog.spaces[0].projects[0].loadState == .loading)

    manager.setProjectLoadState(.ready, projectID: projectID, spaceID: spaceID)
    #expect(manager.catalog.spaces[0].projects[0].loadState == .ready)

    // Dedup — setting the same value again is a no-op (same final state, no throw).
    manager.setProjectLoadState(.ready, projectID: projectID, spaceID: spaceID)
    #expect(manager.catalog.spaces[0].projects[0].loadState == .ready)

    manager.setProjectLoadState(.failed(reason: "gone"), projectID: projectID, spaceID: spaceID)
    #expect(manager.catalog.spaces[0].projects[0].loadState == .failed(reason: "gone"))
  }

  @Test
  func setProjectLoadStateMissingProjectIsSilentNoOp() {
    let bogusSpace = SpaceID()
    let bogusProject = ProjectID()
    manager.setProjectLoadState(.ready, projectID: bogusProject, spaceID: bogusSpace)
    #expect(manager.catalog.spaces.isEmpty)
  }

  @Test
  func isPathRegisteredReturnsPairForCanonicalizedMatch() throws {
    let spaceID = manager.createSpace(name: "work")
    let projectID = try manager.addProject(
      to: spaceID,
      name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/p")
    )

    let match = manager.isPathRegistered(canonical: HierarchyManager.canonicalPath("/tmp/p"))
    #expect(match?.0 == spaceID)
    #expect(match?.1 == projectID)

    // The canonical form strips symlinks and trailing slashes — callers always
    // pass canonical paths. Passing a non-canonical form intentionally does NOT
    // match, enforcing the contract.
    let absent = manager.isPathRegistered(canonical: "/tmp/p/")
    #expect(absent == nil)
  }

  @Test
  func isPathRegisteredReturnsNilWhenAbsent() {
    let match = manager.isPathRegistered(canonical: "/does/not/exist")
    #expect(match == nil)
  }

  // MARK: - project(containing:) — Codex P2-4

  @Test
  func projectContainingMatchesRootExactly() throws {
    let spaceID = manager.createSpace(name: "work")
    let projectID = try manager.addProject(
      to: spaceID, name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/p")
    )
    let match = manager.project(containing: HierarchyManager.canonicalPath("/tmp/p"))
    #expect(match?.0 == spaceID)
    #expect(match?.1 == projectID)
  }

  @Test
  func projectContainingMatchesSubdirectoryOfRoot() throws {
    let spaceID = manager.createSpace(name: "work")
    let projectID = try manager.addProject(
      to: spaceID, name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/p")
    )
    // `tc open` from a subdirectory must still resolve to the parent Project, so the
    // project's `defaultEditor` override applies to arbitrarily deep paths.
    let subPath = HierarchyManager.canonicalPath("/tmp/p") + "/src/Features"
    let match = manager.project(containing: subPath)
    #expect(match?.1 == projectID)
  }

  @Test
  func projectContainingRespectsPathSegmentBoundary() throws {
    let spaceID = manager.createSpace(name: "work")
    _ = try manager.addProject(
      to: spaceID, name: "p",
      rootPath: HierarchyManager.canonicalPath("/tmp/repo")
    )
    // `/tmp/repo` must not match `/tmp/repository`; prefix-match on the raw string alone
    // would incorrectly match, so the implementation anchors on `/` segment boundaries.
    let absent = manager.project(containing: "/tmp/repository")
    #expect(absent == nil)
  }

  @Test
  func projectContainingPicksDeepestMatchWhenProjectsNest() throws {
    // Monorepo with a nested sub-project — deepest root wins so the closest override is
    // applied, not the outer monorepo's override.
    let spaceID = manager.createSpace(name: "work")
    let outerID = try manager.addProject(
      to: spaceID, name: "outer",
      rootPath: HierarchyManager.canonicalPath("/tmp/mono")
    )
    let innerID = try manager.addProject(
      to: spaceID, name: "inner",
      rootPath: HierarchyManager.canonicalPath("/tmp/mono/apps/web")
    )
    let innerPath = HierarchyManager.canonicalPath("/tmp/mono/apps/web") + "/src/pages"
    let match = manager.project(containing: innerPath)
    #expect(match?.1 == innerID)
    #expect(match?.1 != outerID)

    // Outside the inner project but inside the outer — falls back to outer.
    let outerPath = HierarchyManager.canonicalPath("/tmp/mono") + "/packages"
    let outerMatch = manager.project(containing: outerPath)
    #expect(outerMatch?.1 == outerID)
  }

  @Test
  func projectContainingReturnsNilWhenNoProjectContains() {
    let match = manager.project(containing: "/var/no/project/here")
    #expect(match == nil)
  }

  // MARK: - drainLegacyOverrides — v1 catalog migration bridge

  /// Builds a fresh manager whose catalog was decoded from a v1 payload carrying the
  /// two legacy-only Project fields. This is the closest approximation to production
  /// ordering: the catalog is loaded first (v1 decoder populates `defaultEditor` /
  /// `worktreesDirectory` into the in-memory Project), then `drainLegacyOverrides`
  /// runs to hand those values off to SettingsStore.
  private static func makeManagerFromV1Catalog(
    projectUUID: UUID = UUID(),
    spaceUUID: UUID = UUID(),
    defaultEditor: EditorID? = nil,
    worktreesDirectory: String? = nil
  ) throws -> (HierarchyManager, ProjectID) {
    let editorField = defaultEditor.map { "\"defaultEditor\": \"\($0)\"," } ?? ""
    let wtField = worktreesDirectory.map { "\"worktreesDirectory\": \"\($0)\"," } ?? ""
    let json = #"""
      {
        "version": 1,
        "spaces": [
          {
            "id": "\#(spaceUUID.uuidString)",
            "name": "s",
            "projects": [
              {
                "id": { "raw": "\#(projectUUID.uuidString)" },
                "name": "p",
                "rootPath": "/tmp/p",
                \#(editorField)
                \#(wtField)
                "worktrees": []
              }
            ]
          }
        ]
      }
      """#
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
    let tempURL = FileManager.default.temporaryDirectory.appending(
      component: UUID().uuidString + ".json"
    )
    let store = CatalogStore(fileURL: tempURL)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: runtime)
    return (manager, ProjectID(raw: projectUUID))
  }

  @Test
  func drainLegacyOverridesReturnsMapAndClearsFields() throws {
    let (manager, projectID) = try Self.makeManagerFromV1Catalog(
      defaultEditor: "vscode",
      worktreesDirectory: "/tmp/wt"
    )

    let overrides = manager.drainLegacyOverrides()
    #expect(overrides.count == 1)
    #expect(overrides[projectID]?.defaultEditor == "vscode")
    #expect(overrides[projectID]?.worktreesDirectory == "/tmp/wt")
    #expect(manager.catalog.spaces[0].projects[0].defaultEditor == nil)
    #expect(manager.catalog.spaces[0].projects[0].worktreesDirectory == nil)
  }

  @Test
  func drainLegacyOverridesOnCleanCatalogReturnsEmptyMap() throws {
    let (manager, _) = try Self.makeManagerFromV1Catalog()
    let overrides = manager.drainLegacyOverrides()
    #expect(overrides.isEmpty)
  }

  @Test
  func drainLegacyOverridesIsIdempotent() throws {
    let (manager, _) = try Self.makeManagerFromV1Catalog(defaultEditor: "vscode")
    let first = manager.drainLegacyOverrides()
    let second = manager.drainLegacyOverrides()
    #expect(first.count == 1)
    #expect(second.isEmpty, "Second drain must see empty fields")
  }

  // MARK: - Tab-bar uplift (M2-T2.1)

  /// Seeds a worktree with three tabs and returns (space, project, worktree, tabIDs).
  /// Every tab gets one pane so `closeTab`'s runtime-teardown path is exercised
  /// the same way the real UI drives it.
  @MainActor
  private func makeFixtureWithThreeTabs() throws -> (SpaceID, ProjectID, WorktreeID, [TabID]) {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(
      to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    var tabIDs: [TabID] = []
    for name in ["one", "two", "three"] {
      let tid = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: name)
      _ = try manager.openPane(
        in: tid, in: worktreeID, in: projectID, in: spaceID,
        workingDirectory: "/tmp", initialCommand: nil
      )
      tabIDs.append(tid)
    }
    return (spaceID, projectID, worktreeID, tabIDs)
  }

  @Test
  func renameTabWritesName() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.renameTab(tabs[1], in: wt, in: pr, in: sp, name: "renamed")
    let stored = manager.catalog.spaces[0].projects[0].worktrees[0].tabs[1].name
    #expect(stored == "renamed")
  }

  @Test
  func renameTabWithUnchangedNameIsNoOp() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Same value → no throw, still equals the original.
    try manager.renameTab(tabs[0], in: wt, in: pr, in: sp, name: "one")
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs[0].name == "one")
  }

  @Test
  func renameTabThrowsOnMissingID() throws {
    let (sp, pr, wt, _) = try makeFixtureWithThreeTabs()
    #expect(throws: HierarchyError.self) {
      try manager.renameTab(TabID(), in: wt, in: pr, in: sp, name: "nope")
    }
  }

  @Test
  func reorderTabsAcceptsPermutation() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    let permuted = [tabs[2], tabs[0], tabs[1]]
    try manager.reorderTabs(in: wt, in: pr, in: sp, orderedIDs: permuted)
    let stored = manager.catalog.spaces[0].projects[0].worktrees[0].tabs.map(\.id)
    #expect(stored == permuted)
  }

  @Test
  func reorderTabsRejectsMismatchedSet() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Drop the last id → set mismatch → invariantViolation.
    let shortened = Array(tabs.dropLast())
    #expect(throws: HierarchyError.self) {
      try manager.reorderTabs(in: wt, in: pr, in: sp, orderedIDs: shortened)
    }
  }

  @Test
  func closeOtherTabsKeepsPivotSelected() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.closeOtherTabs(keeping: tabs[1], in: wt, in: pr, in: sp)
    let remaining = manager.catalog.spaces[0].projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == [tabs[1]])
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabs[1])
  }

  @Test
  func closeTabsToRightTrimsSuffix() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.closeTabsToRight(of: tabs[0], in: wt, in: pr, in: sp)
    let remaining = manager.catalog.spaces[0].projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == [tabs[0]])
  }

  @Test
  func closeTabsToRightNoOpForLastTab() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    try manager.closeTabsToRight(of: tabs.last!, in: wt, in: pr, in: sp)
    let remaining = manager.catalog.spaces[0].projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == tabs)
  }

  @Test
  func closeTabsToRightKeepsPivotSelectedWhenActiveWasDoomed() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // makeFixtureWithThreeTabs leaves the last tab selected; ask to
    // close everything to the right of the first one. The user's
    // active tab is in the doomed suffix, so without the explicit
    // reseat the auto-advance would land on `tabs.first` regardless
    // of which pivot was passed.
    try manager.closeTabsToRight(of: tabs[0], in: wt, in: pr, in: sp)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabs[0])
  }

  @Test
  func closeTabsToRightKeepsPivotSelectedWhenPivotIsMid() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Pivot is the middle tab; auto-advance would otherwise land on
    // tabs[0] when tabs[2] (the active tab) closes.
    try manager.closeTabsToRight(of: tabs[1], in: wt, in: pr, in: sp)
    let remaining = manager.catalog.spaces[0].projects[0].worktrees[0].tabs.map(\.id)
    #expect(remaining == [tabs[0], tabs[1]])
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabs[1])
  }

  @Test
  func closeAllTabsEmptiesWorktree() throws {
    let (sp, pr, wt, _) = try makeFixtureWithThreeTabs()
    try manager.closeAllTabs(in: wt, in: pr, in: sp)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.isEmpty)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == nil)
  }

  @Test
  func selectAdjacentTabWrapsForward() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // After makeFixtureWithThreeTabs the last-created tab is selected.
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabs[2])
    let next = try manager.selectAdjacentTab(direction: .next, in: wt, in: pr, in: sp)
    #expect(next == tabs[0])
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabs[0])
  }

  @Test
  func selectAdjacentTabWrapsBackward() throws {
    let (sp, pr, wt, tabs) = try makeFixtureWithThreeTabs()
    // Selected is tabs[2]; previous from 2 is 1, from 0 is 2 (wrap). Check both.
    _ = try manager.selectTab(tabs[0], in: wt, in: pr, in: sp)
    let previous = try manager.selectAdjacentTab(direction: .previous, in: wt, in: pr, in: sp)
    #expect(previous == tabs[2])
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].selectedTabID == tabs[2])
  }

  @Test
  func selectAdjacentTabReturnsNilOnEmptyWorktree() throws {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(
      to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    let result = try manager.selectAdjacentTab(
      direction: .next, in: worktreeID, in: projectID, in: spaceID
    )
    #expect(result == nil)
  }

  // MARK: - Runtime state: focus memory + dirty (M3-T3.5)

  /// Seeds a worktree with two tabs. Tab A has two panes (so we can
  /// remember "the second pane"), tab B has one pane (so selectTab has
  /// a fallback leaf on the other side).
  @MainActor
  private func makeFixtureTwoTabsWithPanes() throws -> (
    SpaceID, ProjectID, WorktreeID, TabID, TabID, PaneID, PaneID, PaneID
  ) {
    let spaceID = manager.createSpace(name: "test")
    let projectID = try manager.addProject(
      to: spaceID, name: "project", rootPath: "/tmp", gitRoot: "/tmp"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "main", path: "/repo", branch: "main"
    )
    let tabA = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: "A")
    let tabAPane1 = try manager.openPane(
      in: tabA, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp", initialCommand: nil
    )
    let tabAPane2 = try manager.splitPane(
      tabAPane1, direction: .right,
      in: tabA, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp", initialCommand: nil
    )
    let tabB = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: "B")
    let tabBPane = try manager.openPane(
      in: tabB, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/tmp", initialCommand: nil
    )
    return (spaceID, projectID, worktreeID, tabA, tabB, tabAPane1, tabAPane2, tabBPane)
  }

  @Test
  func selectTabRestoresLastFocusedPane() throws {
    let (sp, pr, wt, tabA, tabB, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    // Remember tabA's second pane, then bounce through tabB and back.
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr, in: sp)
    fakeRuntime.reset()
    try manager.selectTab(tabB, in: wt, in: pr, in: sp)
    try manager.selectTab(tabA, in: wt, in: pr, in: sp)
    // Selecting tabA restores tabAPane2 (focusSurfaceView called with it).
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(tabAPane2))
  }

  @Test
  func selectTabFallsBackToLeftmostLeafWhenRememberedPaneClosed() throws {
    let (sp, pr, wt, tabA, tabB, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr, in: sp)
    // The remembered pane disappears out from under us.
    try manager.closePane(tabAPane2, in: tabA, in: wt, in: pr, in: sp)
    fakeRuntime.reset()
    try manager.selectTab(tabB, in: wt, in: pr, in: sp)
    try manager.selectTab(tabA, in: wt, in: pr, in: sp)
    // Fallback: leftmost leaf of tabA's tree = tabAPane1.
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(tabAPane1))
  }

  @Test
  func closePaneClearsLastFocusedAndRunningEntries() throws {
    let (sp, pr, wt, tabA, _, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr, in: sp)
    manager.markPaneRunning(tabAPane2)
    #expect(manager.lastFocusedPane(in: tabA) == tabAPane2)
    #expect(manager.tabIsDirty(tabA))
    try manager.closePane(tabAPane2, in: tabA, in: wt, in: pr, in: sp)
    #expect(manager.lastFocusedPane(in: tabA) == nil)
    #expect(!manager.tabIsDirty(tabA))
  }

  @Test
  func closeTabClearsRuntimeMapsForAllPanes() throws {
    let (sp, pr, wt, tabA, _, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    try manager.focusPane(tabAPane1, in: tabA, in: wt, in: pr, in: sp)
    manager.markPaneRunning(tabAPane2)
    try manager.closeTab(tabA, in: wt, in: pr, in: sp)
    #expect(manager.lastFocusedPane(in: tabA) == nil)
    // Dirty read on a now-absent tab: the walk finds no tab → false.
    #expect(!manager.tabIsDirty(tabA))
  }

  @Test
  func selectAdjacentTabRestoresLastFocusedPaneOnTarget() throws {
    let (sp, pr, wt, tabA, tabB, _, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    // Remember tabA's second pane, then bounce to tabB so adjacency
    // jumps land back on tabA.
    try manager.focusPane(tabAPane2, in: tabA, in: wt, in: pr, in: sp)
    try manager.selectTab(tabB, in: wt, in: pr, in: sp)
    fakeRuntime.reset()
    let landed = try manager.selectAdjacentTab(
      direction: .previous, in: wt, in: pr, in: sp
    )
    #expect(landed == tabA)
    #expect(fakeRuntime.focusSurfaceViewCalls.contains(tabAPane2))
  }

  @Test
  func tabIsDirtyReflectsAnyRunningPane() throws {
    let (_, _, _, tabA, _, tabAPane1, tabAPane2, _) = try makeFixtureTwoTabsWithPanes()
    #expect(!manager.tabIsDirty(tabA))
    manager.markPaneRunning(tabAPane1)
    #expect(manager.tabIsDirty(tabA))
    manager.markPaneIdle(tabAPane1)
    #expect(!manager.tabIsDirty(tabA))
    manager.markPaneRunning(tabAPane2)
    #expect(manager.tabIsDirty(tabA))
  }
}
