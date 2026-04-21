import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore
@testable import touch_code

@MainActor
struct WorktreeHeaderFeatureTests {
  // MARK: - Fixtures

  /// A catalog with one Space / one Project / one Worktree / one Panel and
  /// matching IDs, plus a helper inbox builder so tests can mix unreads,
  /// reads, and orphans succinctly.
  private struct Fixture {
    let catalog: Catalog
    let spaceID: SpaceID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let panelID: PanelID

    init() {
      let panel = Panel(workingDirectory: "/a")
      let worktree = Worktree(
        name: "w", path: "/a",
        tabs: [Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])]
      )
      let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
      let space = Space(name: "s", projects: [project])
      self.catalog = Catalog(spaces: [space], selectedSpaceID: space.id)
      self.spaceID = space.id
      self.projectID = project.id
      self.worktreeID = worktree.id
      self.panelID = panel.id
    }

    func unread(_ title: String = "n", panelID: PanelID? = nil) -> AgentNotification {
      AgentNotification(
        panelID: panelID ?? self.panelID,
        agent: "claude",
        kind: .completed,
        title: title, body: "", createdAt: Date()
      )
    }
  }

  // MARK: - Observation + badge

  @Test
  func inboxUpdatedStoresSnapshot() async {
    let f = Fixture()
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    let inbox = NotificationInbox(notifications: [f.unread("a"), f.unread("b")])
    await store.send(.inboxUpdated(inbox)) { state in
      state.inbox = inbox
    }
    #expect(store.state.unreadCount(in: f.catalog) == 2)
  }

  /// Parity contract (design doc §Badge/popover parity): the bell badge count
  /// and the popover's rendered row count share one `PanelID -> WorktreeID`
  /// resolution. One valid unread + one orphan unread (panelID not in the
  /// catalog) must yield `unreadCount == 1` *and* a popover grouping with
  /// exactly one rendered notification row.
  @Test
  func unreadBadgeAndPopoverRowsAgreeOnOrphans() async {
    let f = Fixture()
    let orphan = f.unread("ghost", panelID: PanelID())
    let inbox = NotificationInbox(notifications: [f.unread("valid"), orphan])

    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.inboxUpdated(inbox)) { state in
      state.inbox = inbox
    }

    // Badge counts unreads whose panel resolves in the catalog.
    #expect(store.state.unreadCount(in: f.catalog) == 1)

    // Popover grouping walks the same index; flattened row count agrees.
    let groups = HeaderBellPopover.groupProjectByWorktree(inbox: inbox, catalog: f.catalog)
    let renderedRows = groups.flatMap { $0.worktrees.flatMap { $0.notifications } }
    #expect(renderedRows.count == 1)
    #expect(renderedRows.first?.title == "valid")
  }

  /// A catalog-only mutation (e.g. the worktree that owned a panel is
  /// removed) must be enough to collapse the badge count — no inbox or
  /// selection event required. Tested at the `State.unreadCount(in:)`
  /// level because that's the function views call on every render pass;
  /// SwiftUI observation of `hierarchyManager.catalog` drives the redraw.
  @Test
  func unreadCountDropsWhenPanelOrphansViaCatalogMutation() {
    let f = Fixture()
    let state = WorktreeHeaderFeature.State(
      inbox: NotificationInbox(notifications: [f.unread("x")])
    )
    #expect(state.unreadCount(in: f.catalog) == 1)

    // Same inbox, different catalog: the panel is no longer resolvable
    // (empty catalog) — the count drops without any action dispatch.
    let emptyCatalog = Catalog()
    #expect(state.unreadCount(in: emptyCatalog) == 0)
  }

  // MARK: - Row tap chain

  @Test
  func notificationTappedChainsSelectionAndMarksRead() async {
    let f = Fixture()
    let recordedSpace = LockIsolated<SpaceID?>(nil)
    let recordedProject = LockIsolated<(ProjectID, SpaceID)?>(nil)
    let recordedWorktree = LockIsolated<(WorktreeID?, ProjectID, SpaceID)?>(nil)
    let recordedMarkRead = LockIsolated<WorktreeID?>(nil)

    let store = TestStore(
      initialState: WorktreeHeaderFeature.State(popoverOpen: true)
    ) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0[InboxClient.self].markReadForWorktree = { id, _ in recordedMarkRead.setValue(id) }
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { f.catalog }
      $0.hierarchyClient.selectSpace = { recordedSpace.setValue($0) }
      $0.hierarchyClient.selectProject = { pid, sid in
        recordedProject.setValue((pid ?? ProjectID(), sid))
      }
      $0.hierarchyClient.selectWorktree = { wid, pid, sid in
        recordedWorktree.setValue((wid, pid, sid))
      }
    }

    await store.send(.notificationTapped(
      spaceID: f.spaceID, projectID: f.projectID, worktreeID: f.worktreeID
    )) { state in
      state.popoverOpen = false
    }
    #expect(recordedSpace.value == f.spaceID)
    #expect(recordedProject.value?.0 == f.projectID)
    #expect(recordedProject.value?.1 == f.spaceID)
    #expect(recordedWorktree.value?.0 == f.worktreeID)
    #expect(recordedMarkRead.value == f.worktreeID)
  }

  // MARK: - Dismiss all

  @Test
  func dismissAllTappedCallsClearAll() async {
    let fired = LockIsolated(false)
    let store = TestStore(
      initialState: WorktreeHeaderFeature.State(popoverOpen: true)
    ) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0[InboxClient.self].clearAll = { fired.setValue(true) }
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { Catalog() }
    }
    await store.send(.dismissAllTapped) { state in
      state.popoverOpen = false
    }
    #expect(fired.value == true)
  }

  // MARK: - GV toggle

  @Test
  func gitViewerToggledDispatchesFlip() async {
    let recorded = LockIsolated<(WorktreeID, Bool)?>(nil)
    let worktreeID = WorktreeID()
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.setWorktreeGitViewerVisible = { id, v in
        recorded.setValue((id, v))
      }
    }
    await store.send(.gitViewerToggled(worktreeID: worktreeID, currentVisibility: false))
    #expect(recorded.value?.0 == worktreeID)
    #expect(recorded.value?.1 == true)

    await store.send(.gitViewerToggled(worktreeID: worktreeID, currentVisibility: true))
    #expect(recorded.value?.1 == false)
  }

  // MARK: - Delegates

  @Test
  func openDefaultEditorEmitsDelegate() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    let pid = ProjectID()
    await store.send(.openDefaultEditorTapped(worktreePath: "/tmp/w", projectID: pid))
    await store.receive(
      .delegate(.openEditor(editorID: nil, worktreePath: "/tmp/w", projectID: pid))
    )
  }

  @Test
  func openEditorByIDEmitsDelegate() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.openEditorTapped(editorID: "vscode", worktreePath: "/tmp/w", projectID: nil))
    await store.receive(
      .delegate(.openEditor(editorID: "vscode", worktreePath: "/tmp/w", projectID: nil))
    )
  }

  @Test
  func customEditorsEmitsDelegate() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.customEditorsTapped)
    await store.receive(.delegate(.showCustomEditorsSettings))
  }

  @Test
  func setProjectDefaultEmitsDelegate() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    let spaceID = SpaceID()
    let projectID = ProjectID()
    await store.send(.setProjectDefaultEditorTapped(
      spaceID: spaceID, projectID: projectID, editorID: "cursor"
    ))
    await store.receive(.delegate(.setProjectOverride(
      projectID: projectID, spaceID: spaceID, editorID: "cursor"
    )))
  }

  // MARK: - Popover

  @Test
  func popoverToggledUpdatesState() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.popoverToggled(true)) { $0.popoverOpen = true }
    await store.send(.popoverToggled(false)) { $0.popoverOpen = false }
  }
}
