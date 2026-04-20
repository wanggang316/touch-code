import Foundation
import Testing

@testable import touch_code

@MainActor
struct PermissionDelegateTests {
  @Test
  func nullDelegateAlwaysReturnsContinue() async {
    let delegate = NullPermissionDelegate()
    #expect(await delegate.presentPrompt() == .continue)
  }

  @Test
  func permissionDecisionRoundTripsThroughJSON() throws {
    for decision in [PermissionDecision.continue, .notNow, .never] {
      let data = try JSONEncoder().encode(decision)
      let decoded = try JSONDecoder().decode(PermissionDecision.self, from: data)
      #expect(decoded == decision)
    }
  }
}
