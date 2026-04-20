import Foundation
import Testing

@testable import TouchCodeCore

struct MuteSettingsTests {
  @Test
  func defaultsRoundTrip() throws {
    let settings = MuteSettings.defaults
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(MuteSettings.self, from: data)
    #expect(decoded == settings)
  }

  @Test
  func defaultsMatchDesignSpec() {
    let settings = MuteSettings.defaults
    // Design §Muting: global enabled + badge visible; idle suppressed; no redaction.
    #expect(settings.enabled == true)
    #expect(settings.badgeEnabled == true)
    #expect(settings.surfaceIdle == false)
    #expect(settings.redactBodies == false)
    #expect(settings.mutedRuleIDs.isEmpty)
    #expect(settings.mutedPanelIDs.isEmpty)
  }

  @Test
  func populatedSettingsRoundTrip() throws {
    let original = MuteSettings(
      enabled: true,
      badgeEnabled: false,
      surfaceIdle: true,
      redactBodies: true,
      mutedRuleIDs: ["claude.completed", "codex.blocked_on_input"],
      mutedPanelIDs: [PanelID(), PanelID()]
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MuteSettings.self, from: data)
    #expect(decoded == original)
  }
}
