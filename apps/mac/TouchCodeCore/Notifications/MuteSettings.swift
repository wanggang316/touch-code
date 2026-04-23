import Foundation

/// User preferences that gate whether a given `AgentNotification` transition
/// reaches the OS banner or the Dock badge. Owned by a SettingsStore in M4;
/// mutated by `NotificationCoordinator` and the eventual `tc notifications
/// mute` CLI verb. Lives in `TouchCodeCore` so CLI callers can decode without
/// importing Runtime or the notifications module.
///
/// Semantics (design §Cross-Cutting / §Muting):
/// - `enabled` — global kill switch; when false, no OS post, no badge, no inbox add.
/// - `badgeEnabled` — hide the Dock badge even while the inbox accrues.
/// - `surfaceIdle` — whether `.idle` transitions are posted to the OS (default false).
/// - `redactBodies` — replace the OS-visible body with "(redacted)" while keeping
///   the original in the local-only inbox.
/// - `mutedRuleIDs` / `mutedPaneIDs` — per-rule / per-pane OS-post mute; inbox
///   still accrues and the badge still increments (design DEC-13).
public nonisolated struct MuteSettings: Equatable, Codable, Sendable {
  public var enabled: Bool
  public var badgeEnabled: Bool
  public var surfaceIdle: Bool
  public var redactBodies: Bool
  public var mutedRuleIDs: Set<String>
  public var mutedPaneIDs: Set<PaneID>

  public init(
    enabled: Bool = true,
    badgeEnabled: Bool = true,
    surfaceIdle: Bool = false,
    redactBodies: Bool = false,
    mutedRuleIDs: Set<String> = [],
    mutedPaneIDs: Set<PaneID> = []
  ) {
    self.enabled = enabled
    self.badgeEnabled = badgeEnabled
    self.surfaceIdle = surfaceIdle
    self.redactBodies = redactBodies
    self.mutedRuleIDs = mutedRuleIDs
    self.mutedPaneIDs = mutedPaneIDs
  }

  public static let defaults = MuteSettings()
}
