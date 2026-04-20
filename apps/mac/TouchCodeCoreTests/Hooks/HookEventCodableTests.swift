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
    #expect(HookEvent.panelCreated.rawValue == "panel.created")
    #expect(HookEvent.panelOutputMatch.rawValue == "panel.outputMatch")
    #expect(HookEvent.tabAutoClosed.rawValue == "tab.autoClosed")
    #expect(HookEvent.worktreeActivated.rawValue == "worktree.activated")
  }

  @Test
  func scopePartitionsEventsCorrectly() throws {
    #expect(HookEvent.panelReady.scope == .panel)
    #expect(HookEvent.panelInput.scope == .panel)
    #expect(HookEvent.panelOutputMatch.scope == .panel)
    #expect(HookEvent.tabActivated.scope == .tab)
    #expect(HookEvent.worktreeRemoved.scope == .worktree)
  }

  @Test
  func panelInputIsFirstClass() throws {
    // `panel.input` was added in the C3 v2 review fix and must be part of
    // `allCases` so `HookConfig` validators accept it.
    #expect(HookEvent.allCases.contains(.panelInput))
  }
}
