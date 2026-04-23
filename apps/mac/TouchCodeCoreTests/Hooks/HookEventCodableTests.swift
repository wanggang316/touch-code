import Foundation
import Testing

@testable import TouchCodeCore

struct HookEventCodableTests {
  @Test
  func everyCaseRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for event in HookEvent.allCases {
      let data = try encoder.encode(event)
      let decoded = try decoder.decode(HookEvent.self, from: data)
      #expect(decoded == event)
    }
  }

  @Test
  func wireStringIsStable() throws {
    #expect(HookEvent.paneCreated.rawValue == "pane.created")
    #expect(HookEvent.paneOutputMatch.rawValue == "pane.outputMatch")
    #expect(HookEvent.tabAutoClosed.rawValue == "tab.autoClosed")
    #expect(HookEvent.worktreeActivated.rawValue == "worktree.activated")
  }

  @Test
  func scopePartitionsEventsCorrectly() throws {
    #expect(HookEvent.paneReady.scope == .pane)
    #expect(HookEvent.paneInput.scope == .pane)
    #expect(HookEvent.paneOutputMatch.scope == .pane)
    #expect(HookEvent.tabActivated.scope == .tab)
    #expect(HookEvent.worktreeRemoved.scope == .worktree)
  }

  @Test
  func paneInputIsFirstClass() throws {
    // `pane.input` was added in the C3 v2 review fix and must be part of
    // `allCases` so `HookConfig` validators accept it.
    #expect(HookEvent.allCases.contains(.paneInput))
  }
}
