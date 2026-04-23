import Foundation
import Testing

@testable import TouchCodeCore

struct AgentStateTransitionTests {
  @Test
  func ruleTriggerRoundTrip() throws {
    let transition = Self.makeTransition(trigger: .rule(id: "claude.completed"))
    let decoded = try Self.roundTrip(transition)
    #expect(decoded == transition)
    if case .rule(let id) = decoded.trigger {
      #expect(id == "claude.completed")
    } else {
      Issue.record("Expected .rule; got \(decoded.trigger)")
    }
  }

  @Test
  func envelopeTriggerRoundTrip() throws {
    let transition = Self.makeTransition(trigger: .envelope(event: .paneExited))
    let decoded = try Self.roundTrip(transition)
    #expect(decoded == transition)
    if case .envelope(let event) = decoded.trigger {
      #expect(event == .paneExited)
    } else {
      Issue.record("Expected .envelope; got \(decoded.trigger)")
    }
  }

  @Test
  func idleTimerTriggerRoundTrip() throws {
    let transition = Self.makeTransition(trigger: .idleTimer(seconds: 120))
    let decoded = try Self.roundTrip(transition)
    #expect(decoded == transition)
    if case .idleTimer(let seconds) = decoded.trigger {
      #expect(seconds == 120)
    } else {
      Issue.record("Expected .idleTimer; got \(decoded.trigger)")
    }
  }

  @Test
  func userOverrideTriggerRoundTrip() throws {
    let transition = Self.makeTransition(trigger: .userOverride)
    let decoded = try Self.roundTrip(transition)
    #expect(decoded == transition)
    #expect(decoded.trigger == .userOverride)
  }

  @Test
  func allFsmStatesRoundTrip() throws {
    for from in AgentState.allCases {
      for to in AgentState.allCases {
        let transition = Self.makeTransition(from: from, to: to, trigger: .userOverride)
        let decoded = try Self.roundTrip(transition)
        #expect(decoded.from == from)
        #expect(decoded.to == to)
      }
    }
  }

  // MARK: - Helpers

  private static func makeTransition(
    from: AgentState = .running,
    to: AgentState = .completed,
    trigger: AgentStateTransition.Trigger
  ) -> AgentStateTransition {
    AgentStateTransition(
      paneID: PaneID(),
      from: from,
      to: to,
      at: Date(timeIntervalSince1970: 1_700_000_000),
      trigger: trigger
    )
  }

  private static func roundTrip(_ value: AgentStateTransition) throws -> AgentStateTransition {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(AgentStateTransition.self, from: data)
  }
}
