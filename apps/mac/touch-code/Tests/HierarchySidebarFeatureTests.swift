import ComposableArchitecture
import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

@MainActor
struct HierarchySidebarFeatureTests {
  @Test
  func toggleSpaceExpansionFlipsSet() async {
    let spaceID = SpaceID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }

    await store.send(.toggleSpaceExpansion(spaceID)) {
      $0.expandedSpaceIDs.insert(spaceID)
    }
    await store.send(.toggleSpaceExpansion(spaceID)) {
      $0.expandedSpaceIDs.remove(spaceID)
    }
  }

  @Test
  func toggleProjectExpansionFlipsSet() async {
    let projectID = ProjectID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }

    await store.send(.toggleProjectExpansion(projectID)) {
      $0.expandedProjectIDs.insert(projectID)
    }
    await store.send(.toggleProjectExpansion(projectID)) {
      $0.expandedProjectIDs.remove(projectID)
    }
  }

  @Test
  func worktreeRowTappedForwardsToHierarchyClient() async {
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let received = LockIsolated<(WorktreeID?, ProjectID, SpaceID)?>(nil)

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.selectWorktree = { id, project, space in
        received.withValue { $0 = (id, project, space) }
      }
      // Empty snapshot → the lastActive-dedup branch finds no matching space
      // and skips the setSpaceLastActiveWorktree write.
      $0.hierarchyClient.snapshot = {
        Catalog(windows: [], spaces: [], selectedSpaceID: nil)
      }
    }

    await store.send(.worktreeRowTapped(worktreeID, inProject: projectID, inSpace: spaceID))
    let captured = received.value
    #expect(captured != nil)
    // Preserve the nil-vs-value distinction — a regression where the
    // reducer accidentally nils out the ID would now fail loudly instead
    // of silently synthesising a fresh WorktreeID.
    #expect(captured?.0 == worktreeID)
    #expect(captured?.1 == projectID)
    #expect(captured?.2 == spaceID)
  }

  // MARK: - nextUntitledSpaceName

  @Test
  func nextUntitledSpaceNameOnEmptyCatalogIsBare() {
    #expect(nextUntitledSpaceName(in: []) == "Untitled Space")
  }

  @Test
  func nextUntitledSpaceNameWithOnlyBareReturnsTwo() {
    let spaces = [Self.space(named: "Untitled Space")]
    #expect(nextUntitledSpaceName(in: spaces) == "Untitled Space 2")
  }

  @Test
  func nextUntitledSpaceNameFillsHoleBetweenBareAndThree() {
    let spaces = [
      Self.space(named: "Untitled Space"),
      Self.space(named: "Untitled Space 3"),
      Self.space(named: "My Project"),
    ]
    #expect(nextUntitledSpaceName(in: spaces) == "Untitled Space 2")
  }

  @Test
  func nextUntitledSpaceNameBareWinsWhenOnlyTwoExists() {
    let spaces = [Self.space(named: "Untitled Space 2")]
    #expect(nextUntitledSpaceName(in: spaces) == "Untitled Space")
  }

  private static func space(named name: String) -> Space {
    Space(id: SpaceID(), name: name, projects: [], selectedProjectID: nil)
  }

  // MARK: - Space switch choreography (M6)

  /// Two-Space catalog fixture: A has Project P with W1 (selected) and W2;
  /// B has Project Q with W3 and W4 (selected). `B.lastActiveWorktreeID` is
  /// caller-configurable so individual tests can exercise the
  /// present / stale / nil branches.
  private struct TwoSpaceFixture {
    let spaceA: SpaceID
    let spaceB: SpaceID
    let projectP: ProjectID
    let projectQ: ProjectID
    let w1: WorktreeID
    let w2: WorktreeID
    let w3: WorktreeID
    let w4: WorktreeID
    let catalog: Catalog
  }

  private static func twoSpaceFixture(
    bLastActive: WorktreeID? = nil,
    currentSelection: SelectionInCatalog = .spaceA
  ) -> TwoSpaceFixture {
    let spaceA = SpaceID()
    let spaceB = SpaceID()
    let projectP = ProjectID()
    let projectQ = ProjectID()
    let w1 = WorktreeID()
    let w2 = WorktreeID()
    let w3 = WorktreeID()
    let w4 = WorktreeID()

    let projectPValue = Project(
      id: projectP,
      name: "P",
      rootPath: "/tmp/P",
      worktrees: [
        Worktree(id: w1, name: "W1", path: "/tmp/P/W1"),
        Worktree(id: w2, name: "W2", path: "/tmp/P/W2"),
      ],
      selectedWorktreeID: w1
    )
    let projectQValue = Project(
      id: projectQ,
      name: "Q",
      rootPath: "/tmp/Q",
      worktrees: [
        Worktree(id: w3, name: "W3", path: "/tmp/Q/W3"),
        Worktree(id: w4, name: "W4", path: "/tmp/Q/W4"),
      ],
      selectedWorktreeID: w4
    )
    let spaceAValue = Space(
      id: spaceA,
      name: "A",
      projects: [projectPValue],
      selectedProjectID: projectP
    )
    let spaceBValue = Space(
      id: spaceB,
      name: "B",
      projects: [projectQValue],
      selectedProjectID: projectQ,
      lastActiveWorktreeID: bLastActive
    )
    let selected: SpaceID = (currentSelection == .spaceA) ? spaceA : spaceB
    let catalog = Catalog(
      windows: [],
      spaces: [spaceAValue, spaceBValue],
      selectedSpaceID: selected
    )
    return TwoSpaceFixture(
      spaceA: spaceA, spaceB: spaceB,
      projectP: projectP, projectQ: projectQ,
      w1: w1, w2: w2, w3: w3, w4: w4,
      catalog: catalog
    )
  }

  private enum SelectionInCatalog { case spaceA, spaceB }

  /// Recorded calls from overridden HierarchyClient closures.
  private struct ClientCalls: Sendable {
    var setLastActive: [(SpaceID, WorktreeID?)] = []
    var selectSpace: [SpaceID?] = []
    var selectWorktree: [(WorktreeID?, ProjectID, SpaceID)] = []
    var removeWorktree: [(WorktreeID, ProjectID, SpaceID)] = []
    var removeProject: [(ProjectID, SpaceID)] = []
    var renameProject: [(ProjectID, SpaceID, String)] = []
    var createSpace: [String] = []
  }

  /// Installs recorder overrides for every HierarchyClient entry the reducer
  /// may call in these tests. Each override captures into a shared
  /// `LockIsolated<ClientCalls>`. `snapshotProvider` is a closure so tests can
  /// flip the returned Catalog between pre- and post-switch states (the real
  /// manager updates catalog synchronously inside `selectSpace`).
  private static func installRecorders(
    on deps: inout DependencyValues,
    calls: LockIsolated<ClientCalls>,
    snapshotProvider: @escaping @Sendable () -> Catalog,
    createSpaceReturn: SpaceID = SpaceID()
  ) {
    deps.hierarchyClient.snapshot = { snapshotProvider() }
    deps.hierarchyClient.setSpaceLastActiveWorktree = { space, worktree in
      calls.withValue { $0.setLastActive.append((space, worktree)) }
    }
    deps.hierarchyClient.selectSpace = { space in
      calls.withValue { $0.selectSpace.append(space) }
    }
    deps.hierarchyClient.selectWorktree = { worktree, project, space in
      calls.withValue { $0.selectWorktree.append((worktree, project, space)) }
    }
    deps.hierarchyClient.removeWorktree = { worktree, project, space in
      calls.withValue { $0.removeWorktree.append((worktree, project, space)) }
    }
    deps.hierarchyClient.removeProject = { project, space in
      calls.withValue { $0.removeProject.append((project, space)) }
    }
    deps.hierarchyClient.renameProject = { project, space, name in
      calls.withValue { $0.renameProject.append((project, space, name)) }
    }
    deps.hierarchyClient.createSpace = { name in
      calls.withValue { $0.createSpace.append(name) }
      return createSpaceReturn
    }
  }

  @Test
  func spaceSwitchWritesOldAndRestoresNew() async {
    let fix = Self.twoSpaceFixture(bLastActive: nil, currentSelection: .spaceA)
    // After-switch catalog: selectedSpaceID = B; B.lastActiveWorktreeID = w4.
    var postSwitchCatalog = fix.catalog
    postSwitchCatalog.selectedSpaceID = fix.spaceB
    postSwitchCatalog.spaces[1].lastActiveWorktreeID = fix.w4
    let preSwitch = LockIsolated<Catalog>(fix.catalog)
    let post = postSwitchCatalog
    let calls = LockIsolated(ClientCalls())

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { preSwitch.value }
      )
      // Flip snapshot to the post-switch catalog when selectSpace is called.
      deps.hierarchyClient.selectSpace = { space in
        calls.withValue { $0.selectSpace.append(space) }
        preSwitch.setValue(post)
      }
    }

    await store.send(.spaceRowTapped(fix.spaceB))

    let recorded = calls.value
    #expect(recorded.setLastActive.count == 1)
    #expect(recorded.setLastActive[0].0 == fix.spaceA)
    #expect(recorded.setLastActive[0].1 == fix.w1)
    #expect(recorded.selectSpace == [fix.spaceB])
    #expect(recorded.selectWorktree.count == 1)
    #expect(recorded.selectWorktree[0].0 == fix.w4)
    #expect(recorded.selectWorktree[0].1 == fix.projectQ)
    #expect(recorded.selectWorktree[0].2 == fix.spaceB)
  }

  @Test
  func spaceSwitchWithStaleLastActiveClearsAndFallsBack() async {
    let staleID = WorktreeID()
    let fix = Self.twoSpaceFixture(bLastActive: staleID, currentSelection: .spaceA)
    var postSwitchCatalog = fix.catalog
    postSwitchCatalog.selectedSpaceID = fix.spaceB
    let preSwitch = LockIsolated<Catalog>(fix.catalog)
    let post = postSwitchCatalog
    let calls = LockIsolated(ClientCalls())

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { preSwitch.value }
      )
      deps.hierarchyClient.selectSpace = { space in
        calls.withValue { $0.selectSpace.append(space) }
        preSwitch.setValue(post)
      }
    }

    await store.send(.spaceRowTapped(fix.spaceB))

    let recorded = calls.value
    // Outgoing write (A ← W1) and stale clear (B ← nil). Both non-nil / nil
    // entries land through setSpaceLastActiveWorktree.
    #expect(recorded.setLastActive.count == 2)
    #expect(recorded.setLastActive[0].0 == fix.spaceA)
    #expect(recorded.setLastActive[0].1 == fix.w1)
    #expect(recorded.setLastActive[1].0 == fix.spaceB)
    #expect(recorded.setLastActive[1].1 == nil)
    #expect(recorded.selectSpace == [fix.spaceB])
    // No selectWorktree dispatched — fallback to existing Project.selectedWorktreeID
    // resolution handled by the selection stream.
    #expect(recorded.selectWorktree.isEmpty)
  }

  @Test
  func worktreeRowTappedFirstTimeWritesLastActive() async {
    let fix = Self.twoSpaceFixture(bLastActive: nil, currentSelection: .spaceA)
    let calls = LockIsolated(ClientCalls())

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(.worktreeRowTapped(fix.w2, inProject: fix.projectP, inSpace: fix.spaceA))

    let recorded = calls.value
    #expect(recorded.selectWorktree.count == 1)
    #expect(recorded.selectWorktree[0].0 == fix.w2)
    #expect(recorded.setLastActive.count == 1)
    #expect(recorded.setLastActive[0].0 == fix.spaceA)
    #expect(recorded.setLastActive[0].1 == fix.w2)
  }

  @Test
  func spaceRowTappedToSameSpaceIsNoOp() async {
    // `.spaceRowTapped` with `snapshot.selectedSpaceID == target` must
    // short-circuit before any catalog mutation or selection call.
    let fix = Self.twoSpaceFixture(currentSelection: .spaceA)
    let calls = LockIsolated(ClientCalls())

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(.spaceRowTapped(fix.spaceA))

    let recorded = calls.value
    #expect(recorded.setLastActive.isEmpty)
    #expect(recorded.selectSpace.isEmpty)
    #expect(recorded.selectWorktree.isEmpty)
  }

  @Test
  func worktreeRowTappedSecondTimeDoesNotRewriteLastActive() async {
    // Fresh catalog: A.lastActiveWorktreeID == nil. First tap on W2 writes
    // it; second identical tap must dedup (count stays at 1). selectWorktree
    // is NOT deduped — every tap propagates through the selection stream.
    let fix = Self.twoSpaceFixture(currentSelection: .spaceA)
    let calls = LockIsolated(ClientCalls())
    // Stateful snapshot: mirrors real HierarchyManager behavior — a
    // setSpaceLastActiveWorktree call updates the Catalog so the next
    // snapshot() observes the new value.
    let mutableCatalog = LockIsolated(fix.catalog)
    #expect(fix.catalog.spaces[0].lastActiveWorktreeID == nil) // baseline

    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { mutableCatalog.value }
      )
      // Override the recorder-wrapped setLastActive to ALSO mutate the
      // shared catalog so the next .snapshot() sees the write — without
      // this the reducer's dedup branch never fires on the second tap.
      deps.hierarchyClient.setSpaceLastActiveWorktree = { space, worktree in
        calls.withValue { $0.setLastActive.append((space, worktree)) }
        mutableCatalog.withValue { catalog in
          guard let index = catalog.spaces.firstIndex(where: { $0.id == space }) else { return }
          catalog.spaces[index].lastActiveWorktreeID = worktree
        }
      }
    }

    await store.send(.worktreeRowTapped(fix.w2, inProject: fix.projectP, inSpace: fix.spaceA))
    await store.send(.worktreeRowTapped(fix.w2, inProject: fix.projectP, inSpace: fix.spaceA))

    let recorded = calls.value
    #expect(recorded.setLastActive.count == 1)
    #expect(recorded.setLastActive[0].0 == fix.spaceA)
    #expect(recorded.setLastActive[0].1 == fix.w2)
    #expect(recorded.selectWorktree.count == 2)
  }

  // MARK: - Worktree context menu (M6)

  @Test
  func worktreeRemoveTappedThenConfirmedCallsRemoveOnce() async {
    let fix = Self.twoSpaceFixture()
    let calls = LockIsolated(ClientCalls())
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(
      .worktreeRemoveTapped(
        worktreeID: fix.w2,
        inProject: fix.projectP,
        inSpace: fix.spaceA,
        name: "W2"
      )
    ) {
      $0.pendingWorktreeRemoval = PendingWorktreeRemoval(
        worktreeID: fix.w2,
        projectID: fix.projectP,
        spaceID: fix.spaceA,
        displayName: "W2"
      )
    }
    await store.send(.worktreeRemoveConfirmed) {
      $0.pendingWorktreeRemoval = nil
    }

    let recorded = calls.value
    #expect(recorded.removeWorktree.count == 1)
    #expect(recorded.removeWorktree[0].0 == fix.w2)
    #expect(recorded.removeWorktree[0].1 == fix.projectP)
    #expect(recorded.removeWorktree[0].2 == fix.spaceA)
  }

  @Test
  func projectRemoveTappedPopulatesPendingAndConfirmCallsRemove() async {
    let fix = Self.twoSpaceFixture()
    let calls = LockIsolated(ClientCalls())
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(
      .projectRemoveTapped(projectID: fix.projectP, inSpace: fix.spaceA, name: "P")
    ) {
      $0.pendingProjectRemoval = PendingProjectRemoval(
        projectID: fix.projectP,
        spaceID: fix.spaceA,
        displayName: "P"
      )
    }
    await store.send(.projectRemoveConfirmed) {
      $0.pendingProjectRemoval = nil
    }

    let recorded = calls.value
    #expect(recorded.removeProject.count == 1)
    #expect(recorded.removeProject[0].0 == fix.projectP)
    #expect(recorded.removeProject[0].1 == fix.spaceA)
  }

  @Test
  func projectRemoveCancelledClearsWithoutRemoveCall() async {
    let fix = Self.twoSpaceFixture()
    let calls = LockIsolated(ClientCalls())
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(
      .projectRemoveTapped(projectID: fix.projectP, inSpace: fix.spaceA, name: "P")
    ) {
      $0.pendingProjectRemoval = PendingProjectRemoval(
        projectID: fix.projectP,
        spaceID: fix.spaceA,
        displayName: "P"
      )
    }
    await store.send(.projectRemoveCancelled) {
      $0.pendingProjectRemoval = nil
    }

    #expect(calls.value.removeProject.isEmpty)
  }

  @Test
  func worktreeRevealInFinderEmitsDelegate() async {
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }
    await store.send(.worktreeRevealInFinderTapped(path: "/tmp/demo"))
    await store.receive(.delegate(.revealInFinder(path: "/tmp/demo")))
  }

  @Test
  func worktreeOpenInDefaultEditorEmitsDelegate() async {
    let projectID = ProjectID()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    }
    await store.send(
      .worktreeOpenInDefaultEditorTapped(
        worktreeID: WorktreeID(),
        projectID: projectID,
        path: "/tmp/demo"
      )
    )
    await store.receive(
      .delegate(.openInDefaultEditor(worktreePath: "/tmp/demo", projectID: projectID))
    )
  }

  // MARK: - Project rename (M6)

  @Test
  func projectRenameFlow() async {
    let fix = Self.twoSpaceFixture()
    let calls = LockIsolated(ClientCalls())
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(
      .projectRenameTapped(projectID: fix.projectP, inSpace: fix.spaceA, currentName: "P")
    ) {
      $0.renameProjectSheet = RenameProjectSheet(
        projectID: fix.projectP,
        spaceID: fix.spaceA,
        draft: "P"
      )
    }
    await store.send(.projectRenameDraftChanged("P2")) {
      $0.renameProjectSheet?.draft = "P2"
    }
    await store.send(.projectRenameConfirmed) {
      $0.renameProjectSheet = nil
    }

    let recorded = calls.value
    #expect(recorded.renameProject.count == 1)
    #expect(recorded.renameProject[0].0 == fix.projectP)
    #expect(recorded.renameProject[0].1 == fix.spaceA)
    #expect(recorded.renameProject[0].2 == "P2")
  }

  @Test
  func projectRenameCancelledSkipsClient() async {
    let fix = Self.twoSpaceFixture()
    let calls = LockIsolated(ClientCalls())
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { fix.catalog }
      )
    }

    await store.send(
      .projectRenameTapped(projectID: fix.projectP, inSpace: fix.spaceA, currentName: "P")
    ) {
      $0.renameProjectSheet = RenameProjectSheet(
        projectID: fix.projectP,
        spaceID: fix.spaceA,
        draft: "P"
      )
    }
    await store.send(.projectRenameCancelled) {
      $0.renameProjectSheet = nil
    }

    #expect(calls.value.renameProject.isEmpty)
  }

  // MARK: - New Space creation (M6)

  @Test
  func newSpaceOnEmptyCatalogUsesBareName() async {
    let newID = SpaceID()
    let calls = LockIsolated(ClientCalls())
    let emptyCatalog = Catalog(windows: [], spaces: [], selectedSpaceID: nil)

    let initial = HierarchySidebarFeature.State(isSpacePopoverPresented: true)
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { emptyCatalog },
        createSpaceReturn: newID
      )
    }

    await store.send(.spacePopoverNewSpaceTapped) {
      $0.isSpacePopoverPresented = false
    }

    let recorded = calls.value
    #expect(recorded.createSpace == ["Untitled Space"])
    #expect(recorded.selectSpace == [newID])
  }

  @Test
  func newSpaceWithBareExistingReturnsTwo() async {
    let newID = SpaceID()
    let calls = LockIsolated(ClientCalls())
    let existing = Space(
      id: SpaceID(),
      name: "Untitled Space",
      projects: [],
      selectedProjectID: nil
    )
    let catalog = Catalog(
      windows: [],
      spaces: [existing],
      selectedSpaceID: existing.id
    )

    let store = TestStore(initialState: HierarchySidebarFeature.State(isSpacePopoverPresented: true)) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { catalog },
        createSpaceReturn: newID
      )
    }

    await store.send(.spacePopoverNewSpaceTapped) {
      $0.isSpacePopoverPresented = false
    }

    #expect(calls.value.createSpace == ["Untitled Space 2"])
  }

  @Test
  func newSpaceFillsHoleBetweenBareAndThree() async {
    let newID = SpaceID()
    let calls = LockIsolated(ClientCalls())
    let bare = Self.space(named: "Untitled Space")
    let three = Self.space(named: "Untitled Space 3")
    let catalog = Catalog(windows: [], spaces: [bare, three], selectedSpaceID: bare.id)

    let store = TestStore(initialState: HierarchySidebarFeature.State(isSpacePopoverPresented: true)) {
      HierarchySidebarFeature()
    } withDependencies: { deps in
      Self.installRecorders(
        on: &deps,
        calls: calls,
        snapshotProvider: { catalog },
        createSpaceReturn: newID
      )
    }

    await store.send(.spacePopoverNewSpaceTapped) {
      $0.isSpacePopoverPresented = false
    }

    #expect(calls.value.createSpace == ["Untitled Space 2"])
  }

  @Test
  func pruneExpansionSetsDropsStaleIDs() async {
    let live = SpaceID()
    let stale = SpaceID()
    let staleProject = ProjectID()
    let liveProject = ProjectID()

    let initial = HierarchySidebarFeature.State(
      expandedSpaceIDs: [live, stale],
      expandedProjectIDs: [liveProject, staleProject]
    )
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    }

    await store.send(
      .pruneExpansionSets(
        currentSpaceIDs: [live],
        currentProjectIDs: [liveProject]
      )
    ) {
      $0.expandedSpaceIDs = [live]
      $0.expandedProjectIDs = [liveProject]
    }
  }
}
