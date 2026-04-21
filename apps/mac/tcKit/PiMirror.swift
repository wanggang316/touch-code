import Foundation

/// Maps a mirror URL from `agents.json` onto pi's on-disk cache layout under
/// `~/.pi/agent/git/`. Typed so the scheme-stripping lives in exactly one place
/// — `InstallRunner` (post-install verification) and `StatusRunner` (reporting)
/// both read through this helper, so an attacker-controlled mirror cannot end
/// up in one caller's cache path but not the other.
public struct PiMirror: Sendable, Equatable {
  /// Raw mirror URL exactly as it appears in `agents.json`, e.g.
  /// `github.com/wanggang316/touch-code-skill` or `git:github.com/…`.
  public let rawURL: String

  public init(rawURL: String) {
    self.rawURL = rawURL
  }

  /// Scheme-stripped form pi uses as its cache directory name. Accepts the
  /// `git:` and `https://` prefixes the CLI emits and tolerates a trailing slash.
  public var slug: String {
    var s = rawURL
    if s.hasPrefix("git:") { s = String(s.dropFirst("git:".count)) }
    if s.hasPrefix("https://") { s = String(s.dropFirst("https://".count)) }
    if s.hasSuffix("/") { s = String(s.dropLast()) }
    return s
  }

  /// Absolute cache directory pi clones into for this mirror.
  public func cacheDirectory(
    root: URL = PiMirror.defaultCacheRoot
  ) -> URL {
    root.appendingPathComponent(slug, isDirectory: true)
  }

  /// Default pi cache root (`~/.pi/agent/git`). Tests override this to a tmpdir.
  public static let defaultCacheRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".pi/agent/git", isDirectory: true)
}
