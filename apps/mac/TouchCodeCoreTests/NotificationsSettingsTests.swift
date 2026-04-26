import Foundation
import Testing

@testable import TouchCodeCore

/// v2 D5 / D11 added two new fields (`enabled` master toggle,
/// `moveNotifiedWorktreeToTop`). Both ship with `decodeIfPresent` so old
/// `settings.json` files round-trip unchanged.
struct NotificationsSettingsTests {
  @Test
  func defaultsHaveAllToggleFlagsTrue() {
    let s = NotificationsSettings.default
    #expect(s.enabled == true)
    #expect(s.moveNotifiedWorktreeToTop == true)
    #expect(s.inAppEnabled == true)
    #expect(s.systemEnabled == true)
    #expect(s.soundEnabled == true)
    #expect(s.dockBadgeEnabled == true)
  }

  @Test
  func legacyJSONWithoutMasterTogglesDecodesToDefaults() throws {
    // Mimic a pre-v2 settings.json shape — encode a default settings,
    // then strip the new keys before decoding.
    let original = NotificationsSettings.default
    let payload = try JSONEncoder().encode(original)
    var dict = try #require(
      try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    )
    dict.removeValue(forKey: "enabled")
    dict.removeValue(forKey: "moveNotifiedWorktreeToTop")
    let stripped = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(NotificationsSettings.self, from: stripped)
    #expect(decoded.enabled == true)
    #expect(decoded.moveNotifiedWorktreeToTop == true)
  }

  @Test
  func explicitFalseValuesRoundTrip() throws {
    var s = NotificationsSettings.default
    s.enabled = false
    s.moveNotifiedWorktreeToTop = false
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(NotificationsSettings.self, from: data)
    #expect(decoded.enabled == false)
    #expect(decoded.moveNotifiedWorktreeToTop == false)
  }
}
