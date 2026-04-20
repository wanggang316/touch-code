import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

@MainActor
struct TerminalEngineTests {
  private final class MutableClock: @unchecked Sendable {
    var now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  }

  private func makeEngine(
    clock: MutableClock = MutableClock()
  ) -> (TerminalEngine, FakeHierarchyRuntime, HierarchyManager, MutableClock) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let fakeRuntime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
    let engine = TerminalEngine(store: store, hierarchy: manager) { clock.now }
    return (engine, fakeRuntime, manager, clock)
  }

  private func makeEngine() -> (TerminalEngine, FakeHierarchyRuntime) {
    let (engine, runtime, _, _) = makeEngine(clock: MutableClock())
    return (engine, runtime)
  }

  @Test
  func eventStreamEmitsEmittedEventsInOrder() async throws {
    let (engine, _) = makeEngine()
    let tabID = TabID()
    let panelID = PanelID()

    let stream = engine.events()
    var iterator = stream.makeAsyncIterator()

    engine.emit(.panelCreated(panelID, tabID))
    engine.emit(.panelReady(panelID))
    engine.emit(.tabActivated(tabID))
    engine.finishEventStream()

    let first = await iterator.next()
    let second = await iterator.next()
    let third = await iterator.next()

    guard case .panelCreated(let pid1, let tid1) = first else {
      Issue.record("expected panelCreated; got \(String(describing: first))")
      return
    }
    #expect(pid1 == panelID && tid1 == tabID)

    guard case .panelReady(let pid2) = second else {
      Issue.record("expected panelReady; got \(String(describing: second))")
      return
    }
    #expect(pid2 == panelID)

    guard case .tabActivated(let tid3) = third else {
      Issue.record("expected tabActivated; got \(String(describing: third))")
      return
    }
    #expect(tid3 == tabID)
  }

  @Test
  func appendOutputCoalescesIntoSingleEvent() async throws {
    let (engine, _) = makeEngine()
    let panelID = PanelID()
    let stream = engine.events()
    var iterator = stream.makeAsyncIterator()

    engine.appendOutput(panelID: panelID, bytes: Data([0x01, 0x02]))
    engine.appendOutput(panelID: panelID, bytes: Data([0x03]))
    engine.flushOutput(for: panelID)

    let first = await iterator.next()
    guard case .panelOutput(let pid, let data) = first else {
      Issue.record("expected panelOutput; got \(String(describing: first))")
      return
    }
    #expect(pid == panelID)
    #expect(data == Data([0x01, 0x02, 0x03]))
  }

  @Test
  func disposeOutputBufferFlushesPendingBytes() async throws {
    let (engine, _) = makeEngine()
    let panelID = PanelID()
    let stream = engine.events()
    var iterator = stream.makeAsyncIterator()

    engine.appendOutput(panelID: panelID, bytes: Data([0xAA]))
    engine.disposeOutputBuffer(for: panelID)

    let event = await iterator.next()
    guard case .panelOutput(_, let data) = event else {
      Issue.record("expected panelOutput; got \(String(describing: event))")
      return
    }
    #expect(data == Data([0xAA]))
  }

  // MARK: - Crash isolation

  @Test
  func firstCrashSurvivesReturnsTrue() throws {
    let (engine, _, manager, _) = makeEngine(clock: MutableClock())
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(to: spaceID, name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, in: spaceID, name: "w", path: "/w", branch: "main")
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/w", initialCommand: nil
    )

    let survived = engine.recordPanelCrash(panelID: panelID, reason: "segv")
    #expect(survived)
    // Tab still present.
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func threeCrashesWithinWindowAutoClosesTab() throws {
    let clock = MutableClock()
    let (engine, _, manager, clk) = makeEngine(clock: clock)
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(to: spaceID, name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, in: spaceID, name: "w", path: "/w", branch: "main")
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/w", initialCommand: nil
    )

    #expect(engine.recordPanelCrash(panelID: panelID, reason: "1"))
    clk.now = clk.now.addingTimeInterval(5)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "2"))
    clk.now = clk.now.addingTimeInterval(5)
    let survived = engine.recordPanelCrash(panelID: panelID, reason: "3")
    #expect(!survived)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.isEmpty)
  }

  @Test
  func crashesOlderThanWindowDropFromRing() throws {
    let clock = MutableClock()
    let (engine, _, manager, clk) = makeEngine(clock: clock)
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(to: spaceID, name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, in: spaceID, name: "w", path: "/w", branch: "main")
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/w", initialCommand: nil
    )

    // 2 crashes, then advance past window, then 2 more — should survive (ring
    // only has 2 entries after the prune).
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "1"))
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "2"))
    clk.now = clk.now.addingTimeInterval(31)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "3"))
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "4"))
    // Tab should still be alive.
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func retryPanelClearsRingAndEmitsReady() throws {
    let (engine, _, manager, _) = makeEngine(clock: MutableClock())
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(to: spaceID, name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, in: spaceID, name: "w", path: "/w", branch: "main")
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/w", initialCommand: nil
    )

    _ = engine.recordPanelCrash(panelID: panelID, reason: "1")
    _ = engine.recordPanelCrash(panelID: panelID, reason: "2")
    engine.retryPanel(panelID)

    // Two more crashes should now not trigger auto-close (ring was cleared).
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "3"))
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "4"))
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.contains(where: { $0.id == tabID }))
  }
}
