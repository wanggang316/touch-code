import Foundation
import os.log

/// Top-level schema for `~/.config/touch-code/hooks.json`. Version-gated
/// decoder: accepts both v1 (legacy) and v2 (current). The v2 bump widens
/// `HookSubscription.Scope` with `projectID` / `projectPathGlob` cases and
/// makes Scope decoding fail-soft on unknown kinds — a single broken
/// subscription no longer aborts the whole file load.
public nonisolated struct HookConfig: Equatable, Sendable {
  public static let currentVersion = 2
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

  /// Logger for fail-soft subscription skips at load time.
  private static let configLogger = Logger(subsystem: "com.touch-code.hooks", category: "config")

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .version)
    // Accepts v1 (legacy) and v2 (current). In-memory `version` normalises to
    // `currentVersion` so the next save writes v2 shape.
    guard version == 1 || version == HookConfig.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = HookConfig.currentVersion
    self.recursionWindowMs =
      try c.decodeIfPresent(Int.self, forKey: .recursionWindowMs)
      ?? HookConfig.defaultRecursionWindowMs

    // Lossy subscription decoding: each entry tries to decode; a
    // `HookSubscription.Scope.UnknownScopeKind` error (new v2 case the running
    // binary doesn't understand, typo in the `kind` string, etc.) skips that
    // entry with a log line rather than aborting the whole file.
    //
    // The key-exists check is deliberate: only a missing `subscriptions` key defaults
    // to an empty array. A key that exists but holds the wrong type (e.g. an object
    // instead of an array) propagates the DecodingError upward so the outer loader
    // can back the malformed file aside instead of silently clearing the user's hooks.
    if c.contains(.subscriptions) {
      var array = try c.nestedUnkeyedContainer(forKey: .subscriptions)
      var kept: [HookSubscription] = []
      kept.reserveCapacity(array.count ?? 0)
      while !array.isAtEnd {
        do {
          kept.append(try array.decode(HookSubscription.self))
        } catch let err as HookSubscription.Scope.UnknownScopeKind {
          Self.configLogger.warning(
            "Dropping hook subscription with unknown scope kind: \(err.raw, privacy: .public)"
          )
          // Consume the value so the unkeyed container advances.
          _ = try? array.decode(AnyCodableShim.self)
        }
      }
      self.subscriptions = kept
    } else {
      self.subscriptions = []
    }
  }
}

/// One-shot shim used by `HookConfig`'s fail-soft subscription loop to consume
/// an entry whose real decoder threw. `Array.decode` on `UnkeyedDecodingContainer`
/// advances the cursor only when the decode succeeds; to skip a bad entry the
/// decoder has to fetch *something* from that slot so the next iteration sees
/// the next element. `AnyCodableShim` eats any JSON value without failing.
private struct AnyCodableShim: Decodable { init(from _: Decoder) throws {} }
