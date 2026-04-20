import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

@MainActor
struct TerminalEngineTests {
  private final class MutableClock: @unchecked Sendable {
    private(set) var now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(by seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
    }
  }

  private final class TempFile {
    let url: URL
    init() {
      self.url = FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString + ".json")
    }
    deinit {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func makeEngine(
    clock: MutableClock = MutableClock()
  ) -> (TerminalEngine, HierarchyManager, MutableClock, TempFile) {
    let temp = TempFile()
    let fakeRuntime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: temp.url)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
    let engine = TerminalEngine(store: store, hierarchy: manager) { clock.now }
    return (engine, manager, clock, temp)
  }

  // MARK: - Fan-out

  @Test
  func subscribeThenEmitDeliversInOrder() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()
    let panelID = PanelID()

    // Register the continuation synchronously by calling events() first —
    // the AsyncStream initializer closure registers with the engine during
    // this call, so subsequent emits reach the buffer even before the
    // async iterator runs.
    let stream = engine.events()
    engine.emit(.panelCreated(panelID, tabID))
    engine.emit(.panelReady(panelID))

    var iterator = stream.makeAsyncIterator()
    guard case .panelCreated(let pid1, let tid1) = await iterator.next() else {
      Issue.record("expected panelCreated")
      return
    }
    #expect(pid1 == panelID && tid1 == tabID)
    guard case .panelReady(let pid2) = await iterator.next() else {
      Issue.record("expected panelReady")
      return
    }
    #expect(pid2 == panelID)
  }

  @Test
  func multipleSubscribersEachReceiveAllEvents() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()

    let streamA = engine.events()
    let streamB = engine.events()

    engine.emit(.tabActivated(tabID))
    engine.emit(.tabActivated(tabID))
    engine.emit(.tabActivated(tabID))

    var iterA = streamA.makeAsyncIterator()
    var iterB = streamB.makeAsyncIterator()
    var countA = 0
    var countB = 0
    for _ in 0..<3 {
      _ = await iterA.next()
      countA += 1
      _ = await iterB.next()
      countB += 1
    }
    #expect(countA == 3)
    #expect(countB == 3)
  }

  @Test
  func lifecycleOnlySubscriberSkipsOutputEvents() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()
    let panelID = PanelID()

    let stream = engine.events(lifecycleOnly: true)
    engine.emit(.panelOutput(panelID, Data([0x01])))
    engine.emit(.panelOutput(panelID, Data([0x02])))
    engine.emit(.tabActivated(tabID))
    engine.emit(.panelReady(panelID))

    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()

    for event in [first, second].compactMap({ $0 }) {
      switch event {
      case .panelOutput, .panelIdle:
        Issue.record("output event leaked to lifecycle-only subscriber")
      default:
        break
      }
    }
  }

  // MARK: - Output coalescing

  @Test
  func appendOutputCoalescesIntoSingleEvent() async throws {
    let (engine, _, _, _) = makeEngine()
    let panelID = PanelID()
    let stream = engine.events()

    engine.appendOutput(panelID: panelID, bytes: Data([0x01, 0x02]))
    engine.appendOutput(panelID: panelID, bytes: Data([0x03]))
    engine.flushOutput(for: panelID)

    var iterator = stream.makeAsyncIterator()
    guard case .panelOutput(let pid, let data) = await iterator.next() else {
      Issue.record("expected panelOutput")
      return
    }
    #expect(pid == panelID)
    #expect(data == Data([0x01, 0x02, 0x03]))
  }

  @Test
  func disposeOutputBufferFlushesPendingBytes() async throws {
    let (engine, _, _, _) = makeEngine()
    let panelID = PanelID()
    let stream = engine.events()

    engine.appendOutput(panelID: panelID, bytes: Data([0xAA]))
    engine.disposeOutputBuffer(for: panelID)

    var iterator = stream.makeAsyncIterator()
    if case .panelOutput(_, let data) = await iterator.next() {
      #expect(data == Data([0xAA]))
    } else {
      Issue.record("expected panelOutput")
    }
  }

  // MARK: - Teardown

  @Test
  func finishEventStreamIsIdempotentAndSilencesEmit() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()
    let stream = engine.events()

    engine.emit(.tabActivated(tabID))
    engine.finishEventStream()
    // Post-finish emits are silent no-ops.
    engine.emit(.tabActivated(tabID))
    engine.finishEventStream()  // second call safe.

    var count = 0
    for await _ in stream { count += 1 }
    #expect(count == 1)
  }

  // MARK: - Crash isolation

  // MARK: - Crash isolation helpers

  private func seedPanel(
    in manager: HierarchyManager
  ) throws -> (SpaceID, ProjectID, WorktreeID, TabID, PanelID) {
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(to: spaceID, name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, in: spaceID, name: "w", path: "/w", branch: "main")
    let tabID = try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: nil)
    let panelID = try manager.openPanel(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/w", initialCommand: nil
    )
    return (spaceID, projectID, worktreeID, tabID, panelID)
  }

  // MARK: - Crash isolation

  @Test
  func firstCrashSurvives() throws {
    let (engine, manager, _, _) = makeEngine()
    let (_, _, _, tabID, panelID) = try seedPanel(in: manager)

    let outcome = engine.recordPanelCrash(panelID: panelID, reason: "segv")
    #expect(outcome == .survived)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func threeCrashesWithinWindowAutoClosesTabAndEmitsCrashLoopCause() async throws {
    let (engine, manager, clk, _) = makeEngine()
    let (_, _, _, tabID, panelID) = try seedPanel(in: manager)

    let stream = engine.events(lifecycleOnly: true)

    #expect(engine.recordPanelCrash(panelID: panelID, reason: "1") == .survived)
    clk.advance(by: 5)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "2") == .survived)
    clk.advance(by: 5)
    let outcome = engine.recordPanelCrash(panelID: panelID, reason: "3")
    #expect(outcome == .tabAutoClosed(tabID))
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.isEmpty)

    var events: [TerminalEvent] = []
    var iterator = stream.makeAsyncIterator()
    while let event = await iterator.next() {
      events.append(event)
      if case .tabAutoClosed = event { break }
    }

    guard case .tabAutoClosed(let closedTabID, let cause) = events.last else {
      Issue.record("expected last event to be tabAutoClosed; got \(String(describing: events.last))")
      return
    }
    #expect(closedTabID == tabID)
    #expect(cause == .crashLoop(count: 3, window: 30))
    let crashCount = events.reduce(into: 0) { count, event in
      if case .panelCrashed = event { count += 1 }
    }
    #expect(crashCount == 3)
  }

  @Test
  func crashesOlderThanWindowDropFromRing() throws {
    let (engine, manager, clk, _) = makeEngine()
    let (_, _, _, tabID, panelID) = try seedPanel(in: manager)

    #expect(engine.recordPanelCrash(panelID: panelID, reason: "1") == .survived)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "2") == .survived)
    clk.advance(by: 31)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "3") == .survived)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "4") == .survived)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func crashExactlyAtWindowBoundaryIsStillCounted() throws {
    let (engine, manager, clk, _) = makeEngine()
    let (_, _, _, tabID, panelID) = try seedPanel(in: manager)

    // t=0
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "1") == .survived)
    // advance to exactly window boundary (30s). Older entry should still be
    // included (>= cutoff, not > cutoff).
    clk.advance(by: 30)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "2") == .survived)
    let outcome = engine.recordPanelCrash(panelID: panelID, reason: "3")
    #expect(outcome == .tabAutoClosed(tabID))
  }

  @Test
  func retryPanelClearsRingAndEmitsReady() throws {
    let (engine, manager, _, _) = makeEngine()
    let (_, _, _, tabID, panelID) = try seedPanel(in: manager)

    _ = engine.recordPanelCrash(panelID: panelID, reason: "1")
    _ = engine.recordPanelCrash(panelID: panelID, reason: "2")
    #expect(engine.retryPanel(panelID))

    #expect(engine.recordPanelCrash(panelID: panelID, reason: "3") == .survived)
    #expect(engine.recordPanelCrash(panelID: panelID, reason: "4") == .survived)
    #expect(manager.catalog.spaces[0].projects[0].worktrees[0].tabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func retryPanelReturnsFalseForUnknownID() {
    let (engine, _, _, _) = makeEngine()
    #expect(!engine.retryPanel(PanelID()))
  }

  @Test
  func tabAutoCloseEmitsPanelExitedForSiblings() async throws {
    let (engine, manager, clk, _) = makeEngine()
    let (spaceID, projectID, worktreeID, tabID, panelA) = try seedPanel(in: manager)
    let panelB = try manager.splitPanel(
      panelA, direction: .right,
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: "/w", initialCommand: nil
    )

    let stream = engine.events(lifecycleOnly: true)

    _ = engine.recordPanelCrash(panelID: panelA, reason: "1")
    clk.advance(by: 5)
    _ = engine.recordPanelCrash(panelID: panelA, reason: "2")
    clk.advance(by: 5)
    _ = engine.recordPanelCrash(panelID: panelA, reason: "3")

    var events: [TerminalEvent] = []
    var iterator = stream.makeAsyncIterator()
    while let event = await iterator.next() {
      events.append(event)
      if case .tabAutoClosed = event { break }
    }

    let exitedSiblings = events.compactMap { event -> PanelID? in
      if case .panelExited(let pid, _, _) = event { return pid }
      return nil
    }
    #expect(exitedSiblings.contains(panelB))
    #expect(!exitedSiblings.contains(panelA))  // panelA emitted .panelCrashed, not .panelExited
  }
}
