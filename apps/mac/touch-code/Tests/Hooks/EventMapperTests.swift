import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct EventMapperTests {
  @Test
  func paneReadyBuildsFullAnchorChain() {
    let (catalog, paneID, tabID, worktreeID, projectID) = Self.fixture()
    let envelope = EventMapper.map(.paneReady(paneID), catalog: catalog)
    #expect(envelope != nil)
    guard let envelope else { return }
    #expect(envelope.event == .paneReady)
    #expect(envelope.pane?.id == paneID)
    #expect(envelope.tab?.id == tabID)
    #expect(envelope.worktree?.id == worktreeID)
    #expect(envelope.project?.id == projectID)
    if case .paneReady = envelope.data {
    } else {
      Issue.record("expected .paneReady data")
    }
  }

  @Test
  func paneOutputCarriesRawBytes() {
    let (catalog, paneID, _, _, _) = Self.fixture()
    let payload = Data("hello\nworld".utf8)
    let envelope = EventMapper.map(.paneOutput(paneID, payload), catalog: catalog)
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.event == .paneOutput)
    if case .paneOutput(let output, let bytes) = envelope.data {
      #expect(output == payload)
      #expect(bytes == payload.count)
    } else {
      Issue.record("expected .paneOutput data")
    }
  }

  @Test
  func paneExitedCarriesExitCode() {
    let (catalog, paneID, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(.paneExited(paneID, code: 42, signal: nil), catalog: catalog)
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.event == .paneExited)
    if case .paneExited(let code) = envelope.data {
      #expect(code == 42)
    } else {
      Issue.record("expected .paneExited data")
    }
  }

  @Test
  func paneClosedByTabSurfacesAsCrashed() {
    let (catalog, paneID, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(
      .paneClosedByTab(paneID, cause: .crashLoop(count: 3, window: 30)),
      catalog: catalog
    )
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.event == .paneCrashed)
    if case .paneCrashed(let reason) = envelope.data {
      #expect(reason.contains("crashLoop"))
      #expect(reason.contains("3"))
    } else {
      Issue.record("expected .paneCrashed data")
    }
  }

  @Test
  func tabActivatedAnchorsStopAtTab() {
    let (catalog, _, tabID, worktreeID, projectID) = Self.fixture()
    let envelope = EventMapper.map(.tabActivated(tabID), catalog: catalog)
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.event == .tabActivated)
    #expect(envelope.tab?.id == tabID)
    #expect(envelope.worktree?.id == worktreeID)
    #expect(envelope.project?.id == projectID)
    #expect(envelope.pane == nil)
  }

  @Test
  func tabAutoClosedExtractsCrashLoopDetails() {
    let (catalog, _, tabID, _, _) = Self.fixture()
    let envelope = EventMapper.map(
      .tabAutoClosed(tabID, cause: .crashLoop(count: 4, window: 60)),
      catalog: catalog
    )
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.event == .tabAutoClosed)
    if case .tabAutoClosed(let reason, let count, let window) = envelope.data {
      #expect(reason == "crashLoop")
      #expect(count == 4)
      #expect(window == 60)
    } else {
      Issue.record("expected .tabAutoClosed data")
    }
  }

  @Test
  func worktreeActivatedAnchorsStopAtWorktree() {
    let (catalog, _, _, worktreeID, projectID) = Self.fixture()
    let envelope = EventMapper.map(.worktreeActivated(worktreeID), catalog: catalog)
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.event == .worktreeActivated)
    #expect(envelope.worktree?.id == worktreeID)
    #expect(envelope.project?.id == projectID)
    #expect(envelope.tab == nil)
    #expect(envelope.pane == nil)
  }

  @Test
  func hierarchyMutatedHasNoHookSurface() {
    let (catalog, _, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(.hierarchyMutated(.catalog), catalog: catalog)
    #expect(envelope == nil)
  }

  @Test
  func unknownPaneProducesNilAnchors() {
    let (catalog, _, _, _, _) = Self.fixture()
    let stranger = PaneID()
    let envelope = EventMapper.map(.paneReady(stranger), catalog: catalog)
    guard let envelope else {
      Issue.record("expected envelope")
      return
    }
    #expect(envelope.pane == nil)
    #expect(envelope.tab == nil)
    #expect(envelope.worktree == nil)
    #expect(envelope.project == nil)
  }

  // MARK: - Fixture

  static func fixture() -> (Catalog, PaneID, TabID, WorktreeID, ProjectID) {
    let paneID = PaneID()
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let pane = Pane(
      id: paneID,
      workingDirectory: "/tmp/wt",
      initialCommand: "bash",
      labels: ["agent", "experiment"]
    )
    let tab = Tab(id: tabID, name: "main", panes: [pane])
    let worktree = Worktree(
      id: worktreeID,
      name: "wt",
      path: "/tmp/wt",
      branch: "main",
      tabs: [tab]
    )
    let project = Project(
      id: projectID,
      name: "proj",
      rootPath: "/tmp",
      gitRoot: "/tmp/.git",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])
    return (catalog, paneID, tabID, worktreeID, projectID)
  }
}
