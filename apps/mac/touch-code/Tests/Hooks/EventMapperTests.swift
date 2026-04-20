import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore

@MainActor
struct EventMapperTests {
  @Test
  func panelReadyBuildsFullAnchorChain() {
    let (catalog, panelID, tabID, worktreeID, projectID, spaceID) = Self.fixture()
    let envelope = EventMapper.map(.panelReady(panelID), catalog: catalog)
    #expect(envelope != nil)
    guard let envelope else { return }
    #expect(envelope.event == .panelReady)
    #expect(envelope.panel?.id == panelID)
    #expect(envelope.tab?.id == tabID)
    #expect(envelope.worktree?.id == worktreeID)
    #expect(envelope.project?.id == projectID)
    #expect(envelope.space?.id == spaceID)
    if case .panelReady = envelope.data { } else {
      Issue.record("expected .panelReady data")
    }
  }

  @Test
  func panelOutputCarriesRawBytes() {
    let (catalog, panelID, _, _, _, _) = Self.fixture()
    let payload = Data("hello\nworld".utf8)
    let envelope = EventMapper.map(.panelOutput(panelID, payload), catalog: catalog)
    guard let envelope else {
      Issue.record("expected envelope"); return
    }
    #expect(envelope.event == .panelOutput)
    if case .panelOutput(let output, let bytes) = envelope.data {
      #expect(output == payload)
      #expect(bytes == payload.count)
    } else {
      Issue.record("expected .panelOutput data")
    }
  }

  @Test
  func panelExitedCarriesExitCode() {
    let (catalog, panelID, _, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(.panelExited(panelID, code: 42, signal: nil), catalog: catalog)
    guard let envelope else { Issue.record("expected envelope"); return }
    #expect(envelope.event == .panelExited)
    if case .panelExited(let code) = envelope.data {
      #expect(code == 42)
    } else {
      Issue.record("expected .panelExited data")
    }
  }

  @Test
  func panelClosedByTabSurfacesAsCrashed() {
    let (catalog, panelID, _, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(
      .panelClosedByTab(panelID, cause: .crashLoop(count: 3, window: 30)),
      catalog: catalog
    )
    guard let envelope else { Issue.record("expected envelope"); return }
    #expect(envelope.event == .panelCrashed)
    if case .panelCrashed(let reason) = envelope.data {
      #expect(reason.contains("crashLoop"))
      #expect(reason.contains("3"))
    } else {
      Issue.record("expected .panelCrashed data")
    }
  }

  @Test
  func tabActivatedAnchorsStopAtTab() {
    let (catalog, _, tabID, worktreeID, projectID, spaceID) = Self.fixture()
    let envelope = EventMapper.map(.tabActivated(tabID), catalog: catalog)
    guard let envelope else { Issue.record("expected envelope"); return }
    #expect(envelope.event == .tabActivated)
    #expect(envelope.tab?.id == tabID)
    #expect(envelope.worktree?.id == worktreeID)
    #expect(envelope.project?.id == projectID)
    #expect(envelope.space?.id == spaceID)
    #expect(envelope.panel == nil)
  }

  @Test
  func tabAutoClosedExtractsCrashLoopDetails() {
    let (catalog, _, tabID, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(
      .tabAutoClosed(tabID, cause: .crashLoop(count: 4, window: 60)),
      catalog: catalog
    )
    guard let envelope else { Issue.record("expected envelope"); return }
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
    let (catalog, _, _, worktreeID, projectID, spaceID) = Self.fixture()
    let envelope = EventMapper.map(.worktreeActivated(worktreeID), catalog: catalog)
    guard let envelope else { Issue.record("expected envelope"); return }
    #expect(envelope.event == .worktreeActivated)
    #expect(envelope.worktree?.id == worktreeID)
    #expect(envelope.project?.id == projectID)
    #expect(envelope.space?.id == spaceID)
    #expect(envelope.tab == nil)
    #expect(envelope.panel == nil)
  }

  @Test
  func hierarchyMutatedHasNoHookSurface() {
    let (catalog, _, _, _, _, _) = Self.fixture()
    let envelope = EventMapper.map(.hierarchyMutated(.catalog), catalog: catalog)
    #expect(envelope == nil)
  }

  @Test
  func unknownPanelProducesNilAnchors() {
    let (catalog, _, _, _, _, _) = Self.fixture()
    let stranger = PanelID()
    let envelope = EventMapper.map(.panelReady(stranger), catalog: catalog)
    guard let envelope else { Issue.record("expected envelope"); return }
    #expect(envelope.panel == nil)
    #expect(envelope.tab == nil)
    #expect(envelope.worktree == nil)
    #expect(envelope.project == nil)
    #expect(envelope.space == nil)
  }

  // MARK: - Fixture

  static func fixture() -> (Catalog, PanelID, TabID, WorktreeID, ProjectID, SpaceID) {
    let panelID = PanelID()
    let tabID = TabID()
    let worktreeID = WorktreeID()
    let projectID = ProjectID()
    let spaceID = SpaceID()
    let panel = Panel(
      id: panelID,
      workingDirectory: "/tmp/wt",
      initialCommand: "bash",
      labels: ["agent", "experiment"]
    )
    let tab = Tab(id: tabID, name: "main", panels: [panel])
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
    let space = Space(id: spaceID, name: "s", projects: [project])
    let catalog = Catalog(spaces: [space], selectedSpaceID: spaceID)
    return (catalog, panelID, tabID, worktreeID, projectID, spaceID)
  }
}
