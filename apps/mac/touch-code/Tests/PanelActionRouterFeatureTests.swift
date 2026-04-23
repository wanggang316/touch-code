import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// TestStore coverage for every `PanelActionRequest` arm of
/// `PanelActionRouterFeature`. The reducer is a fan-out table, so each
/// assertion only checks that the matching `HierarchyClient` closure is
/// called with the resolved address / decoded parameters; catalog-level
/// semantics live in `HierarchyManager` tests.
///
/// Pattern: override only the closures the arm under test touches, record
/// calls into `LockIsolated` boxes, assert after `store.send(...)` settles.
/// `addressOf` is always stubbed because every non-delegate arm probes it
/// first (missing address → silent no-op).
@MainActor
struct PanelActionRouterFeatureTests {
  // MARK: - Fixture

  /// Minimal one-of-each catalog with a ready `PanelAddress` the reducer
  /// resolves `panelID` to. Using stable IDs keeps the recorded-call
  /// assertions decoupled from `UUID()` randomness.
  private struct Fixture {
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let panelID = PanelID()
    let secondTabID = TabID()
    let secondPanelID = PanelID()

    var address: PanelAddress {
      PanelAddress(
        spaceID: spaceID, projectID: projectID,
        worktreeID: worktreeID, tabID: tabID, panelID: panelID
      )
    }

    /// Catalog shape used by `newSplit` / `gotoSplit` / `toggleSplitZoom`
    /// which read `snapshot()` to find the source panel and its tab. The
    /// second tab exists so `gotoTab(.next)` has a non-trivial target.
    func catalog(zoomed: Bool = false) -> Catalog {
      let panel = Panel(id: panelID, workingDirectory: "/cwd")
      let tab = Tab(
        id: tabID,
        splitTree: SplitTree(root: .leaf(panelID), zoomed: zoomed ? panelID : nil),
        panels: [panel]
      )
      let secondPanel = Panel(id: secondPanelID, workingDirectory: "/cwd2")
      let secondTab = Tab(
        id: secondTabID,
        splitTree: SplitTree(leaf: secondPanelID),
        panels: [secondPanel]
      )
      let worktree = Worktree(
        id: worktreeID, name: "w", path: "/w", tabs: [tab, secondTab]
      )
      let project = Project(
        id: projectID, name: "p", rootPath: "/p", gitRoot: "/p",
        worktrees: [worktree]
      )
      let space = Space(id: spaceID, name: "s", projects: [project])
      return Catalog(spaces: [space], selectedSpaceID: spaceID)
    }
  }

  // MARK: - newTab

  @Test
  func newTabCallsCreateTabWithResolvedAddress() async {
    let f = Fixture()
    let recorded = LockIsolated<(WorktreeID, ProjectID, SpaceID, String?)?>(nil)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.createTab = { wid, pid, sid, name in
        recorded.setValue((wid, pid, sid, name))
        return TabID()
      }
    }

    await store.send(.requested(f.panelID, .newTab))
    #expect(recorded.value?.0 == f.worktreeID)
    #expect(recorded.value?.1 == f.projectID)
    #expect(recorded.value?.2 == f.spaceID)
    #expect(recorded.value?.3 == nil)
  }

  // MARK: - closeTab(.this)

  @Test
  func closeTabThisCallsCloseTab() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, WorktreeID, ProjectID, SpaceID)?>(nil)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.closeTab = { tid, wid, pid, sid in
        recorded.setValue((tid, wid, pid, sid))
      }
    }

    await store.send(.requested(f.panelID, .closeTab(mode: .this)))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.1 == f.worktreeID)
    #expect(recorded.value?.2 == f.projectID)
    #expect(recorded.value?.3 == f.spaceID)
  }

  // MARK: - moveTab

  @Test
  func moveTabCallsMoveTabWithOffset() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, WorktreeID, ProjectID, SpaceID, Int)?>(nil)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.moveTab = { tid, wid, pid, sid, offset in
        recorded.setValue((tid, wid, pid, sid, offset))
      }
    }

    await store.send(.requested(f.panelID, .moveTab(offset: 2)))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.4 == 2)
  }

  // MARK: - gotoTab(.next)

  @Test
  func gotoTabNextCallsSelectTabWithNextTabID() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID?, WorktreeID, ProjectID, SpaceID)?>(nil)
    let catalog = f.catalog()
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.selectTab = { tid, wid, pid, sid in
        recorded.setValue((tid, wid, pid, sid))
      }
    }

    await store.send(.requested(f.panelID, .gotoTab(target: .next)))
    // With two tabs (`tabID`, `secondTabID`) and current index 0, .next → secondTabID.
    #expect(recorded.value?.0 == f.secondTabID)
    #expect(recorded.value?.1 == f.worktreeID)
  }

  // MARK: - newSplit

  @Test
  func newSplitHorizontalCallsSplitPanelWithRightDirection() async {
    let f = Fixture()
    let recorded = LockIsolated<
      (PanelID, SplitTree<PanelID>.NewDirection, TabID, WorktreeID, ProjectID, SpaceID, String)?
    >(nil)
    let catalog = f.catalog()
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.splitPanel = { panelID, dir, tid, wid, pid, sid, cwd, _ in
        recorded.setValue((panelID, dir, tid, wid, pid, sid, cwd))
        return PanelID()
      }
    }

    await store.send(.requested(f.panelID, .newSplit(direction: .right)))
    #expect(recorded.value?.0 == f.panelID)
    #expect(recorded.value?.1 == .right)
    #expect(recorded.value?.2 == f.tabID)
    #expect(recorded.value?.6 == "/cwd")
  }

  // MARK: - gotoSplit

  /// `.left` collapses onto `SplitTree.FocusDirection.previous`. On the
  /// single-leaf tree the fixture's source tab has, `focusTarget(.previous)`
  /// wraps around and returns the same panel — the reducer must still
  /// invoke `focusPanel`, routing the decoded intent even when the
  /// neighbor is the source itself.
  @Test
  func gotoSplitLeftCallsFocusPanelOnResolvedNeighbor() async {
    let f = Fixture()
    let recorded = LockIsolated<(PanelID, TabID, WorktreeID, ProjectID, SpaceID)?>(nil)
    let catalog = f.catalog()
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPanel = { panelID, tid, wid, pid, sid in
        recorded.setValue((panelID, tid, wid, pid, sid))
      }
    }

    await store.send(.requested(f.panelID, .gotoSplit(direction: .left)))
    #expect(recorded.value?.0 == f.panelID)
    #expect(recorded.value?.1 == f.tabID)
    #expect(recorded.value?.2 == f.worktreeID)
  }

  // MARK: - resizeSplit

  @Test
  func resizeSplitCallsResizePanelWithDirectionAndAmount() async {
    let f = Fixture()
    let recorded = LockIsolated<(PanelID, ResizeDirection, Double)?>(nil)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      // resizeSplit does not consult addressOf in the reducer, but the
      // override is cheap insurance against future refactors.
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.resizePanel = { panelID, direction, amount in
        recorded.setValue((panelID, direction, amount))
      }
    }

    await store.send(.requested(f.panelID, .resizeSplit(direction: .up, amount: 0.1)))
    #expect(recorded.value?.0 == f.panelID)
    #expect(recorded.value?.1 == .up)
    #expect(recorded.value?.2 == 0.1)
  }

  // MARK: - equalizeSplits

  @Test
  func equalizeSplitsCallsEqualizeTabSplits() async {
    let f = Fixture()
    let recorded = LockIsolated<(TabID, WorktreeID, ProjectID, SpaceID)?>(nil)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.equalizeTabSplits = { tid, wid, pid, sid in
        recorded.setValue((tid, wid, pid, sid))
      }
    }

    await store.send(.requested(f.panelID, .equalizeSplits))
    #expect(recorded.value?.0 == f.tabID)
    #expect(recorded.value?.1 == f.worktreeID)
  }

  // MARK: - toggleSplitZoom (two branches)

  @Test
  func toggleSplitZoomWhenNotZoomedCallsFocusPanel() async {
    let f = Fixture()
    let focusCalled = LockIsolated<(PanelID, TabID)?>(nil)
    let unzoomCalled = LockIsolated(false)
    let catalog = f.catalog(zoomed: false)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPanel = { panelID, tid, _, _, _ in
        focusCalled.setValue((panelID, tid))
      }
      $0.hierarchyClient.unzoomTab = { _, _, _, _ in unzoomCalled.setValue(true) }
    }

    await store.send(.requested(f.panelID, .toggleSplitZoom))
    #expect(focusCalled.value?.0 == f.panelID)
    #expect(focusCalled.value?.1 == f.tabID)
    #expect(unzoomCalled.value == false)
  }

  @Test
  func toggleSplitZoomWhenZoomedCallsUnzoomTab() async {
    let f = Fixture()
    let focusCalled = LockIsolated(false)
    let unzoomCalled = LockIsolated<(TabID, WorktreeID, ProjectID, SpaceID)?>(nil)
    let catalog = f.catalog(zoomed: true)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in f.address }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.focusPanel = { _, _, _, _, _ in focusCalled.setValue(true) }
      $0.hierarchyClient.unzoomTab = { tid, wid, pid, sid in
        unzoomCalled.setValue((tid, wid, pid, sid))
      }
    }

    await store.send(.requested(f.panelID, .toggleSplitZoom))
    #expect(focusCalled.value == false)
    #expect(unzoomCalled.value?.0 == f.tabID)
    #expect(unzoomCalled.value?.1 == f.worktreeID)
  }

  // MARK: - presentTerminal / toggleCommandPalette (delegates)

  @Test
  func presentTerminalEmitsDelegate() async {
    let f = Fixture()
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
    }

    await store.send(.requested(f.panelID, .presentTerminal))
    await store.receive(.delegate(.presentTerminalRequested(f.panelID)))
  }

  @Test
  func toggleCommandPaletteEmitsDelegate() async {
    let f = Fixture()
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
    }

    await store.send(.requested(f.panelID, .toggleCommandPalette))
    await store.receive(.delegate(.commandPaletteToggleRequested(f.panelID)))
  }

  // MARK: - addressOf nil (teardown race)

  /// Reducer must never crash when `addressOf` returns `nil` — the router
  /// is called on the ghostty action callback thread, so a `panelID` that
  /// raced teardown is expected. No mutation closure should fire.
  @Test
  func missingAddressIsSilentNoOp() async {
    let f = Fixture()
    let createTabCalled = LockIsolated(false)
    let closeTabCalled = LockIsolated(false)
    let moveTabCalled = LockIsolated(false)
    let store = TestStore(initialState: PanelActionRouterFeature.State()) {
      PanelActionRouterFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.addressOf = { _ in nil }
      $0.hierarchyClient.createTab = { _, _, _, _ in
        createTabCalled.setValue(true)
        return TabID()
      }
      $0.hierarchyClient.closeTab = { _, _, _, _ in closeTabCalled.setValue(true) }
      $0.hierarchyClient.moveTab = { _, _, _, _, _ in moveTabCalled.setValue(true) }
    }

    await store.send(.requested(f.panelID, .newTab))
    await store.send(.requested(f.panelID, .closeTab(mode: .this)))
    await store.send(.requested(f.panelID, .moveTab(offset: 1)))
    #expect(createTabCalled.value == false)
    #expect(closeTabCalled.value == false)
    #expect(moveTabCalled.value == false)
  }
}
