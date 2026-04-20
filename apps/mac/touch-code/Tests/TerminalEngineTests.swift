import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

@MainActor
struct TerminalEngineTests {
  private func makeEngine() -> (TerminalEngine, FakeHierarchyRuntime) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let fakeRuntime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
    let engine = TerminalEngine(store: store, hierarchy: manager)
    return (engine, fakeRuntime)
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
}
