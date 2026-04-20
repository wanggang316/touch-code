import Foundation

/// Top-level schema for `~/.config/touch-code/hooks.json`. Version-gated
/// decoder follows the same pattern as `Catalog`.
public nonisolated struct HookConfig: Equatable, Sendable {
  public static let currentVersion = 1
  public static let defaultRecursionWindowMs = 250

  public var version: Int
  public var recursionWindowMs: Int
  public var subscriptions: [HookSubscription]

  public init(
    version: Int = HookConfig.currentVersion,
    recursionWindowMs: Int = HookConfig.defaultRecursionWindowMs,
    subscriptions: [HookSubscription] = []
  ) {
    self.version = version
    self.recursionWindowMs = recursionWindowMs
    self.subscriptions = subscriptions
  }

  public static let empty = HookConfig()

  /// Canonical on-disk location: `~/.config/touch-code/hooks.json`.
  public static func defaultURL(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("hooks.json", isDirectory: false)
  }
}

extension HookConfig: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case version, recursionWindowMs, subscriptions
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .version)
    guard version == HookConfig.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = version
    self.recursionWindowMs = try c.decodeIfPresent(Int.self, forKey: .recursionWindowMs)
      ?? HookConfig.defaultRecursionWindowMs
    self.subscriptions = try c.decodeIfPresent([HookSubscription].self, forKey: .subscriptions) ?? []
  }
}
