import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct TerminalClientTests {
  private func makeLiveEngine() -> (TerminalClient, TerminalEngine) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    // ghosttyRuntime = nil: we exercise events() and closure wiring, not
    // actual surface creation (requires a real GhosttyRuntime + window).
    let engine = TerminalEngine(store: store, hierarchy: manager)
    return (TerminalClient.live(engine: engine), engine)
  }

  @Test
  func liveEventsStreamBroadcastsEmittedEvents() async {
    let (client, engine) = makeLiveEngine()
    let stream = client.events()
    let panelID = PanelID()
    let tabID = TabID()

    engine.emit(.panelReady(panelID))
    engine.emit(.tabActivated(tabID))

    var iterator = stream.makeAsyncIterator()
    if case .panelReady(let pid) = await iterator.next() {
      #expect(pid == panelID)
    } else {
      Issue.record("expected panelReady first")
    }
    if case .tabActivated(let tid) = await iterator.next() {
      #expect(tid == tabID)
    } else {
      Issue.record("expected tabActivated second")
    }
  }

  @Test
  func liveEnsureSurfaceThrowsWhenAddressUnknown() {
    let (client, _) = makeLiveEngine()
    do {
      try client.ensureSurface(
        PanelID(), TabID(), WorktreeID(), ProjectID(), SpaceID()
      )
      Issue.record("ensureSurface should throw for unknown address")
    } catch TerminalClient.Error.worktreeNotFound {
      // expected
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}
