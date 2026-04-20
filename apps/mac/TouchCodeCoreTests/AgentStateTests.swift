import Foundation
import Testing

@testable import TouchCodeCore

struct AgentStateTests {
  @Test
  func allCasesRoundTripThroughJSON() throws {
    for state in AgentState.allCases {
      let data = try JSONEncoder().encode(state)
      let decoded = try JSONDecoder().decode(AgentState.self, from: data)
      #expect(decoded == state)
    }
  }

  @Test
  func jsonRepresentationUsesLiteralRawValues() throws {
    let cases: [(AgentState, String)] = [
      (.running, "\"running\""),
      (.completed, "\"completed\""),
      (.blockedOnInput, "\"blockedOnInput\""),
      (.idle, "\"idle\""),
    ]
    for (state, expected) in cases {
      let data = try JSONEncoder().encode(state)
      #expect(String(data: data, encoding: .utf8) == expected)
    }
  }

  @Test
  func unknownRawValueFailsToDecode() throws {
    let payload = Data("\"mystery\"".utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AgentState.self, from: payload)
    }
  }
}
