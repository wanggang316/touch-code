import Foundation

/// Enumerates installed login shells on this machine. Backs the per-Project
/// "Default Shell" picker in the Settings General sub-pane.
///
/// Discovery walks `/etc/shells`, drops comments / blank lines, and keeps
/// only entries whose path actually exists on disk. macOS ships a small
/// curated list there (`/bin/zsh`, `/bin/bash`, …) and Homebrew writes
/// `/opt/homebrew/bin/fish` etc. on `brew install`, so the file is the
/// canonical source of truth without us having to probe `$PATH` ourselves.
///
/// `Provider` exists so tests can inject a fake list without touching the
/// real filesystem; the same shape `EditorRegistry` uses for its descriptor
/// table — registry-as-data, resolution as a separate concern.
public nonisolated enum ShellRegistry {
  /// Source of installed shell paths. Production uses
  /// `Provider.etcShells`; tests inject a `Provider.fixed(...)`.
  public struct Provider: Sendable {
    public let read: @Sendable () -> [String]

    public init(read: @escaping @Sendable () -> [String]) {
      self.read = read
    }

    /// Default provider — parses `/etc/shells` and filters by file existence.
    public static let etcShells = Provider {
      readEtcShells(at: "/etc/shells", fileManager: FileManager.default)
    }

    /// Stub provider for tests. Returns the supplied list verbatim, no
    /// filesystem touch.
    public static func fixed(_ shells: [String]) -> Provider {
      Provider { shells }
    }
  }

  /// Default-Shell picker source list. Empty when no shells resolve — the
  /// picker copes by rendering only the inherit row.
  public static var installed: [String] {
    Provider.etcShells.read()
  }

  /// Read installed shells from the supplied provider. Used by views that
  /// hold a non-default `Provider` (tests).
  public static func installed(via provider: Provider) -> [String] {
    provider.read()
  }

  /// Parse `/etc/shells`-shaped content. Lines starting with `#` are
  /// comments and blank lines are dropped; every remaining line is checked
  /// for `isExecutableFile` so an entry left over from a removed install
  /// (e.g. `/usr/local/bin/fish` after Homebrew migrated to `/opt`) does
  /// not appear in the picker.
  static func readEtcShells(at path: String, fileManager: FileManager) -> [String] {
    guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
      return []
    }
    var seen: Set<String> = []
    var result: [String] = []
    for raw in data.split(separator: "\n", omittingEmptySubsequences: true) {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }
      if seen.contains(trimmed) {
        continue
      }
      if fileManager.isExecutableFile(atPath: trimmed) {
        seen.insert(trimmed)
        result.append(trimmed)
      }
    }
    return result
  }
}
