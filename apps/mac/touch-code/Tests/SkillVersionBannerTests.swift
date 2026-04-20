import Foundation
import Testing
import tcKit
@testable import touch_code

@MainActor
struct SkillVersionBannerTests {
  @Test
  func hiddenWhenBundledVersionIsUnresolvable() {
    let banner = SkillVersionBanner(
      bundleVersionProvider: { nil },
      installedVersionProvider: { _ in "0.1.0" },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    #expect(banner.status == .hidden)
  }

  @Test
  func hiddenWhenInstalledEqualsBundled() {
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.1.0" },
      installedVersionProvider: { _ in "0.1.0" },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    #expect(banner.status == .hidden)
  }

  @Test
  func hiddenWhenNothingInstalled() {
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.1.0" },
      installedVersionProvider: { _ in nil },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    #expect(banner.status == .hidden)
  }

  @Test
  func needsUpgradeWhenInstalledLagsBundled() {
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.2.0" },
      installedVersionProvider: { agent in agent == .claudeCode ? "0.1.0" : nil },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    #expect(banner.status == .needsUpgrade(agent: .claudeCode, installed: "0.1.0", bundled: "0.2.0"))
  }

  @Test
  func stopsAtFirstLaggingAgent() {
    // Both claude-code and codex lag; iteration order of AgentID.allCases is claudeCode
    // → codex → pi. We expect the banner to report the first one and ignore the rest.
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.2.0" },
      installedVersionProvider: { _ in "0.1.0" },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    guard case .needsUpgrade(let agent, _, _) = banner.status else {
      Issue.record("expected needsUpgrade")
      return
    }
    #expect(agent == .claudeCode)
  }

  @Test
  func dismissHidesBannerAndPersists() {
    let defaults = Self.ephemeralDefaults()
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.2.0" },
      installedVersionProvider: { _ in "0.1.0" },
      defaults: defaults
    )
    banner.check()
    #expect(banner.status != .hidden)
    banner.dismiss()
    #expect(banner.status == .hidden)
    #expect(defaults.string(forKey: SkillVersionBanner.dismissKey(for: .claudeCode)) == "0.2.0")
  }

  @Test
  func dismissedBannerStaysHiddenOnRecheckUntilBundleVersionBumps() {
    let defaults = Self.ephemeralDefaults()
    let bundled = LockedBundleVersion(initial: "0.2.0")
    // Only claude-code has an install; codex + pi return nil so dismissal for
    // claude-code alone is sufficient to hide the banner.
    let banner = SkillVersionBanner(
      bundleVersionProvider: { bundled.value },
      installedVersionProvider: { agent in agent == .claudeCode ? "0.1.0" : nil },
      defaults: defaults
    )
    banner.check()
    banner.dismiss()

    banner.check()
    #expect(banner.status == .hidden)

    // Bump the bundled version — the banner should re-arm (same agent, new bundled).
    bundled.value = "0.3.0"
    banner.check()
    guard case .needsUpgrade(let agent, _, let newBundled) = banner.status else {
      Issue.record("expected banner to rearm")
      return
    }
    #expect(agent == .claudeCode)
    #expect(newBundled == "0.3.0")
  }

  @Test
  func dismissalIsPerAgent() {
    // Dismissing claude-code must NOT hide a separate codex upgrade nudge.
    let defaults = Self.ephemeralDefaults()
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.2.0" },
      installedVersionProvider: { _ in "0.1.0" },
      defaults: defaults
    )
    banner.check()
    banner.dismiss() // dismisses claude-code for 0.2.0

    banner.check()
    guard case .needsUpgrade(let agent, _, _) = banner.status else {
      Issue.record("expected codex to surface after claude-code was dismissed")
      return
    }
    #expect(agent == .codex)
  }

  @Test
  func dismissDoesNothingWhenStatusAlreadyHidden() {
    let defaults = Self.ephemeralDefaults()
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.1.0" },
      installedVersionProvider: { _ in "0.1.0" },
      defaults: defaults
    )
    banner.check()
    #expect(banner.status == .hidden)
    banner.dismiss()
    // Nothing persisted because there was no pending upgrade.
    #expect(defaults.string(forKey: SkillVersionBanner.dismissKey(for: .claudeCode)) == nil)
  }

  @Test
  func installedNewerThanBundledDoesNotNag() {
    // Developer override: someone points TOUCH_CODE_SKILL_BUNDLE at an older bundle and
    // already has a newer skill installed. The banner should stay hidden — an "upgrade"
    // nudge going backwards is noise.
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.1.0" },
      installedVersionProvider: { agent in agent == .claudeCode ? "0.2.0" : nil },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    #expect(banner.status == .hidden)
  }

  @Test
  func semverOrderingHandlesTwoDigitMinor() {
    // String-wise "0.10.0" < "0.9.0", but numerically "0.9.0" < "0.10.0". The banner's
    // `.numeric` comparison must pick the numeric order.
    #expect(SkillVersionBanner.isOlder("0.9.0", than: "0.10.0"))
    #expect(!SkillVersionBanner.isOlder("0.10.0", than: "0.9.0"))
    #expect(!SkillVersionBanner.isOlder("0.1.0", than: "0.1.0"))
  }

  @Test
  func piAgentSkippedAtLoopSiteEvenIfProviderReturnsLaggingVersion() {
    // `tc skill install --pi` shells out to pi; there's no actionable upgrade CTA for
    // the banner to surface. Regression guard against comment/code drift.
    let banner = SkillVersionBanner(
      bundleVersionProvider: { "0.2.0" },
      installedVersionProvider: { agent in agent == .pi ? "0.1.0" : nil },
      defaults: Self.ephemeralDefaults()
    )
    banner.check()
    #expect(banner.status == .hidden)
  }

  // MARK: - Helpers

  /// Per-test `UserDefaults` so tests don't pollute each other or the real domain.
  static func ephemeralDefaults() -> UserDefaults {
    let suiteName = "SkillVersionBannerTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return UserDefaults.standard
    }
    return defaults
  }
}

/// Tiny MainActor-scoped box so the closure closing over it can observe mutations.
@MainActor
private final class LockedBundleVersion {
  var value: String
  init(initial: String) { self.value = initial }
}
