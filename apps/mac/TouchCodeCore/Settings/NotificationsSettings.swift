import Foundation
import os.log

/// `notifications` sub-tree of `settings.json` (v3, additive in v1.1). Carries the
/// global on/off knobs for the v1.1 notifications system — in-app inbox, system
/// banners, sound, dock badge — plus the "command finished" detector knobs and the
/// per-rule / per-pane mute sets. The section is optional in the parent decode so
/// pre-v1.1 `settings.json` files keep loading; missing fields fall back to defaults
/// via `decodeIfPresent`.
///
/// All fields are written explicitly on encode (no `encodeIfPresent`, no
/// "skip-if-default" elisions) so a settings.json diff makes the user's notification
/// state visible at a glance.
public nonisolated struct NotificationsSettings: Equatable, Sendable, Codable {
  /// In-app inbox surface. When false the inbox does not collect or display new
  /// entries; existing entries are preserved on disk.
  public var inAppEnabled: Bool
  /// System-level `UserNotifications` banners. When false the OS banner / Notification
  /// Center entry is suppressed even if the in-app inbox accepts the notification.
  public var systemEnabled: Bool
  /// Optional sound on system delivery. Honoured only when `systemEnabled` is also true.
  public var soundEnabled: Bool
  /// Dock-tile unread badge. Independent of `inAppEnabled` because the badge can act as
  /// a peripheral cue even when the user hides the inbox.
  public var dockBadgeEnabled: Bool
  /// Promote the worktree associated with a freshly delivered notification to the top
  /// of the sidebar's recency-sorted list.
  public var moveNotifiedWorktreeToTop: Bool
  /// Master switch for the "command finished" detector. When false, the detector
  /// produces nothing regardless of threshold.
  public var commandFinishedEnabled: Bool
  /// Minimum runtime (seconds) before a finished command qualifies for a notification.
  /// Clamped to `[1, 3600]` on decode; values outside the range trigger a single
  /// warning log line and are replaced with the clamped value.
  public var commandFinishedThresholdSec: Int
  /// Per-rule and per-pane mute sets. Empty by default.
  public var mute: MuteSettings

  public init(
    inAppEnabled: Bool = true,
    systemEnabled: Bool = true,
    soundEnabled: Bool = true,
    dockBadgeEnabled: Bool = true,
    moveNotifiedWorktreeToTop: Bool = true,
    commandFinishedEnabled: Bool = true,
    commandFinishedThresholdSec: Int = 10,
    mute: MuteSettings = .init()
  ) {
    self.inAppEnabled = inAppEnabled
    self.systemEnabled = systemEnabled
    self.soundEnabled = soundEnabled
    self.dockBadgeEnabled = dockBadgeEnabled
    self.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    self.commandFinishedEnabled = commandFinishedEnabled
    self.commandFinishedThresholdSec = Self.clampThreshold(commandFinishedThresholdSec)
    self.mute = mute
  }

  public static let `default` = NotificationsSettings()

  /// Inclusive bounds for `commandFinishedThresholdSec`. The lower bound matches the
  /// detector's minimum meaningful runtime; the upper bound (1 h) is the longest
  /// "still useful" debounce window we'd expect a user to configure interactively.
  static let thresholdRange: ClosedRange<Int> = 1...3600

  private static func clampThreshold(_ value: Int) -> Int {
    min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
  }

  private enum CodingKeys: String, CodingKey {
    case inAppEnabled, systemEnabled, soundEnabled, dockBadgeEnabled
    case moveNotifiedWorktreeToTop
    case commandFinishedEnabled, commandFinishedThresholdSec
    case mute
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.inAppEnabled = try container.decodeIfPresent(Bool.self, forKey: .inAppEnabled) ?? true
    self.systemEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemEnabled) ?? true
    self.soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
    self.dockBadgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockBadgeEnabled) ?? true
    self.moveNotifiedWorktreeToTop =
      try container.decodeIfPresent(Bool.self, forKey: .moveNotifiedWorktreeToTop) ?? true
    self.commandFinishedEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .commandFinishedEnabled) ?? true

    let rawThreshold = try container.decodeIfPresent(Int.self, forKey: .commandFinishedThresholdSec) ?? 10
    let clamped = Self.clampThreshold(rawThreshold)
    if clamped != rawThreshold {
      let logger = Logger(subsystem: "com.touch-code.persistence", category: "settings")
      logger.warning(
        "commandFinishedThresholdSec \(rawThreshold, privacy: .public) out of range [\(Self.thresholdRange.lowerBound, privacy: .public), \(Self.thresholdRange.upperBound, privacy: .public)]; clamped to \(clamped, privacy: .public)"
      )
    }
    self.commandFinishedThresholdSec = clamped

    self.mute = try container.decodeIfPresent(MuteSettings.self, forKey: .mute) ?? .init()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inAppEnabled, forKey: .inAppEnabled)
    try container.encode(systemEnabled, forKey: .systemEnabled)
    try container.encode(soundEnabled, forKey: .soundEnabled)
    try container.encode(dockBadgeEnabled, forKey: .dockBadgeEnabled)
    try container.encode(moveNotifiedWorktreeToTop, forKey: .moveNotifiedWorktreeToTop)
    try container.encode(commandFinishedEnabled, forKey: .commandFinishedEnabled)
    try container.encode(commandFinishedThresholdSec, forKey: .commandFinishedThresholdSec)
    try container.encode(mute, forKey: .mute)
  }
}

/// Mute sets for the notifications system. Rule IDs are opaque strings owned by the
/// rule engine; pane IDs are the canonical `PaneID` from the hierarchy. Both sets are
/// empty by default. Encoded as JSON arrays (Swift `Set`'s synthesised Codable).
public nonisolated struct MuteSettings: Equatable, Sendable, Codable {
  public var mutedRuleIDs: Set<String>
  public var mutedPaneIDs: Set<PaneID>

  public init(
    mutedRuleIDs: Set<String> = [],
    mutedPaneIDs: Set<PaneID> = []
  ) {
    self.mutedRuleIDs = mutedRuleIDs
    self.mutedPaneIDs = mutedPaneIDs
  }

  public static let `default` = MuteSettings()

  private enum CodingKeys: String, CodingKey {
    case mutedRuleIDs, mutedPaneIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.mutedRuleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .mutedRuleIDs) ?? []
    self.mutedPaneIDs = try container.decodeIfPresent(Set<PaneID>.self, forKey: .mutedPaneIDs) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mutedRuleIDs, forKey: .mutedRuleIDs)
    try container.encode(mutedPaneIDs, forKey: .mutedPaneIDs)
  }
}
