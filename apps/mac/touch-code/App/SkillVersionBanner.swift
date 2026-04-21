import Foundation
import Observation
import tcKit

/// Non-blocking launch-time observer that nudges the user when the installed
/// `touch-code-skill` is older than the bundle. Reads **one** field per marker —
/// `version` — via a file-scoped `MinimalMarker` decoder. It never opens `SKILL.md`
/// or any other skill content; that would violate the architecture's orthogonality
/// invariant.
///
/// Dismissal is sticky per bundle version: `dismiss()` persists the current bundle
/// version in `UserDefaults`, so the banner reappears only after `touch-code-skill/VERSION`
/// is bumped.
@MainActor
@Observable
public final class SkillVersionBanner {
  public enum Status: Equatable, Sendable {
    case hidden
    case needsUpgrade(agent: AgentID, installed: String, bundled: String)
  }

  public private(set) var status: Status = .hidden

  /// Closure that returns the bundled skill version (`touch-code-skill/VERSION`) or
  /// nil when unresolvable. Tests pass a literal value; `SkillVersionBanner.live`
  /// wires this to `SkillBundleLocator`.
  public typealias BundleVersionProvider = @MainActor () -> String?

  /// Closure that returns the installed skill version at an agent's default path, or
  /// nil when the agent has no install. Reads are one-field (MinimalMarker.version).
  public typealias InstalledVersionProvider = @MainActor (AgentID) -> String?

  private let bundleVersionProvider: BundleVersionProvider
  private let installedVersionProvider: InstalledVersionProvider
  private let defaults: UserDefaults

  public init(
    bundleVersionProvider: @escaping BundleVersionProvider,
    installedVersionProvider: @escaping InstalledVersionProvider,
    defaults: UserDefaults = .standard
  ) {
    self.bundleVersionProvider = bundleVersionProvider
    self.installedVersionProvider = installedVersionProvider
    self.defaults = defaults
  }

  /// Production factory. Uses `SkillBundleLocator` + `AgentsConfig.loadFromMainBundle`
  /// + `SkillFileSystem` under the covers. Keeps the view layer free of I/O plumbing.
  public static func live(
    fileSystem: SkillFileSystem = RealSkillFileSystem(),
    defaults: UserDefaults = .standard
  ) -> SkillVersionBanner {
    SkillVersionBanner(
      bundleVersionProvider: { Self.readBundledVersion(fileSystem: fileSystem) },
      installedVersionProvider: { agent in
        Self.readInstalledVersion(for: agent, fileSystem: fileSystem)
      },
      defaults: defaults
    )
  }

  /// Polls every copy-mode agent in `AgentID.allCases` — pi is skipped at the loop site
  /// because its cache is managed by pi itself, not by `tc skill install`, so the banner
  /// has no actionable upgrade CTA to surface. On the first lagging install that has not
  /// been dismissed for *this* bundle version, surface `.needsUpgrade` and stop — one
  /// banner at a time.
  ///
  /// Synchronous even though the call-site is `.task { ... }`: the work is pure file
  /// reads plus a `UserDefaults` check, both of which are negligible on launch. Tests
  /// call it directly from `@MainActor`.
  public func check() {
    guard let bundled = bundleVersionProvider() else {
      status = .hidden
      return
    }
    for agent in AgentID.allCases {
      if agent == .pi { continue }  // pi has no `tc skill install --pi` upgrade path
      guard let installed = installedVersionProvider(agent) else { continue }
      if !Self.isOlder(installed, than: bundled) { continue }
      if wasDismissed(for: agent, bundleVersion: bundled) { continue }
      status = .needsUpgrade(agent: agent, installed: installed, bundled: bundled)
      return
    }
    status = .hidden
  }

  /// Compares two version strings using `String.compare(_:options:)` with `.numeric`, so
  /// "0.9.0" < "0.10.0" and "0.1.0" < "0.2.0" behave correctly. An installed version
  /// *newer* than the bundle (dev override, or user manually replaced files) does NOT
  /// trigger the upgrade banner — surfacing "upgrade" in that direction is noise.
  static func isOlder(_ installed: String, than bundled: String) -> Bool {
    installed.compare(bundled, options: .numeric) == .orderedAscending
  }

  /// Records the current `(agent, bundled)` pair as dismissed and hides the banner.
  public func dismiss() {
    guard case .needsUpgrade(let agent, _, let bundled) = status else { return }
    defaults.set(bundled, forKey: Self.dismissKey(for: agent))
    status = .hidden
  }

  private func wasDismissed(for agent: AgentID, bundleVersion: String) -> Bool {
    defaults.string(forKey: Self.dismissKey(for: agent)) == bundleVersion
  }

  public static func dismissKey(for agent: AgentID) -> String {
    "TouchCode.SkillBannerDismissedVersions.\(agent.rawValue)"
  }

  // MARK: - Live provider helpers

  private static func readBundledVersion(fileSystem: SkillFileSystem) -> String? {
    guard let skillURL = try? SkillBundleLocator.locateSkillBundle() else { return nil }
    let versionURL = skillURL.appendingPathComponent("VERSION")
    guard let data = fileSystem.contents(atPath: versionURL.path),
      let text = String(bytes: data, encoding: .utf8)
    else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func readInstalledVersion(
    for agent: AgentID,
    fileSystem: SkillFileSystem
  ) -> String? {
    guard let config = try? AgentsConfig.loadFromMainBundle(),
      let agentConfig = config.config(for: agent),
      agentConfig.installMode == .copy,
      let path = config.defaultPath(for: agent)
    else {
      return nil
    }
    let markerURL = URL(fileURLWithPath: path).appendingPathComponent(".touch-code-skill.json")
    guard let data = fileSystem.contents(atPath: markerURL.path) else { return nil }
    return try? JSONDecoder().decode(MinimalMarker.self, from: data).version
  }
}

/// Single-field decoder — the app reads nothing else from the install marker. The
/// `CodingKeys` whitelist makes the scope explicit: new marker fields can't accidentally
/// land in the app via decode.
private struct MinimalMarker: Decodable {
  let version: String
  enum CodingKeys: String, CodingKey { case version }
}
