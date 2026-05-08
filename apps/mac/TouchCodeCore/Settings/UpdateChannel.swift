import Foundation

/// Sparkle release channel. `stable` ships once a release is cut; `tip` opts the user into
/// pre-release tip-of-tree builds, mapping to the `tip` channel string in the appcast (handled
/// by an `SPUUpdaterDelegate.allowedChannels(for:)` adapter on the app side). Persisted in
/// `GeneralSettings.updateChannel` so the choice survives across launches and is the single
/// source of truth — Sparkle's own preferences are derived from this on bringup.
public nonisolated enum UpdateChannel: String, Equatable, Codable, Sendable, CaseIterable {
  case stable
  case tip

  /// Background-check cadence per channel. `tip` checks more aggressively because the
  /// builds are intentionally short-lived; `stable` only needs the conventional daily
  /// poll. Mirrors supaterm's mapping. The frequency is *not* user-configurable —
  /// channel choice is the single knob.
  public var updateCheckInterval: TimeInterval {
    switch self {
    case .stable: return 86_400  // 24h
    case .tip: return 3600  // 1h
    }
  }

  /// Sparkle channel-string set returned by `allowedChannels(for:)`. An empty set means
  /// "only items with no `<sparkle:channel>` element" — the convention for stable.
  public var sparkleChannels: Set<String> {
    switch self {
    case .stable: return []
    case .tip: return ["tip"]
    }
  }
}
