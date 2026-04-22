import Foundation
import os.log

/// Sorted lists of theme names bundled with / installed for Ghostty, split by
/// perceived luminance of their `background` directive. Consumers (the
/// Appearance settings pane) render two pickers directly from this pair.
///
/// `Equatable` so TCA state can diff; `Sendable` so the struct can cross
/// actor boundaries freely.
struct GhosttyThemeCatalog: Equatable, Sendable {
  /// Theme names whose background luminance classifies as light (Y > 0.5),
  /// sorted with `localizedStandardCompare` so `"abc2"` < `"abc10"`.
  let light: [String]

  /// Theme names that did not classify as light. Includes files without a
  /// parseable `background` directive — Ghostty itself falls back to dark.
  let dark: [String]

  static let empty = GhosttyThemeCatalog(light: [], dark: [])
}

/// Read-only, best-effort enumerator of Ghostty theme files. Never throws;
/// missing directories yield empty arrays. Classification is cheap enough
/// (one line scan per file) to run on demand when the Appearance pane opens.
@MainActor
enum GhosttyThemeCatalogReader {
  private static let logger = Logger(
    subsystem: "app.touch-code.mac",
    category: "appearance"
  )

  /// Enumerate user + app-bundled theme directories and classify each file.
  ///
  /// Priorities (a theme name appearing in more than one directory is
  /// deduplicated; first-seen wins for classification):
  /// 1. `$XDG_CONFIG_HOME/ghostty/themes`
  /// 2. `$HOME/.config/ghostty/themes`
  /// 3. `Bundle.main.resourceURL/ghostty/themes` — app-bundled fallback if
  ///    we ever ship themes as Tuist resources. Currently no-op for static
  ///    GhosttyKit, which doesn't expose a Resources bundle.
  ///
  /// Parameters default to production sources but are injectable for tests.
  static func load(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> GhosttyThemeCatalog {
    let searchRoots = candidateThemeDirectories(
      homeDirectoryURL: homeDirectoryURL,
      environment: environment
    )

    var lightSet: Set<String> = []
    var darkSet: Set<String> = []
    var seen: Set<String> = []

    for root in searchRoots {
      guard let entries = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { continue }

      for entry in entries {
        let name = entry.lastPathComponent
        if seen.contains(name) { continue }
        // Skip sub-directories; Ghostty themes are flat files.
        let isRegular = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isRegular else { continue }
        seen.insert(name)

        switch classify(fileURL: entry) {
        case .light:
          lightSet.insert(name)
        case .dark:
          darkSet.insert(name)
        case .unclassified:
          // Match Ghostty's default fallback. Logged so operators can audit
          // unexpected theme files that don't carry a background directive.
          logger.info("theme-catalog unclassified theme=\(name, privacy: .public)")
          darkSet.insert(name)
        }
      }
    }

    let sort: ([String]) -> [String] = { names in
      names.sorted { lhs, rhs in
        lhs.localizedStandardCompare(rhs) == .orderedAscending
      }
    }
    return GhosttyThemeCatalog(light: sort(Array(lightSet)), dark: sort(Array(darkSet)))
  }

  // MARK: - Search path resolution

  /// Returns every on-disk directory we should probe, in priority order.
  /// Missing directories are still included — the caller `contentsOfDirectory`
  /// short-circuits on ENOENT without error.
  private static func candidateThemeDirectories(
    homeDirectoryURL: URL,
    environment: [String: String]
  ) -> [URL] {
    var roots: [URL] = []
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      roots.append(
        URL(fileURLWithPath: xdg, isDirectory: true)
          .appendingPathComponent("ghostty", isDirectory: true)
          .appendingPathComponent("themes", isDirectory: true)
      )
    }
    roots.append(
      homeDirectoryURL
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("themes", isDirectory: true)
    )
    if let resourceURL = Bundle.main.resourceURL {
      roots.append(
        resourceURL
          .appendingPathComponent("ghostty", isDirectory: true)
          .appendingPathComponent("themes", isDirectory: true)
      )
    }
    return roots
  }

  // MARK: - Classification

  private enum Classification { case light, dark, unclassified }

  /// Read the theme file (best-effort UTF-8) and look for a `background`
  /// directive. Any I/O error or unparseable color → `.unclassified`, which
  /// the caller maps to dark.
  private static func classify(fileURL: URL) -> Classification {
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return .unclassified
    }
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      // Strip `#` comments. A `#RRGGBB` value is distinguished from a
      // comment only by position — comments start the line; color literals
      // appear after `=`.
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard line.lowercased().hasPrefix("background") else { continue }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if let rgb = parseColor(String(value)) {
        let y = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
        return y > 0.5 ? .light : .dark
      }
      return .unclassified
    }
    return .unclassified
  }

  /// Parse the three color formats Ghostty accepts for `background`:
  /// - `#RRGGBB` (hex with leading hash)
  /// - `RRGGBB` (bare hex)
  /// - `r:g:b` (decimal tuple, 0–255 per channel)
  ///
  /// Returned channels are normalized to 0–1.
  fileprivate static func parseColor(_ raw: String) -> (r: Double, g: Double, b: Double)? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.contains(":") {
      let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 3,
            let r = UInt8(parts[0].trimmingCharacters(in: .whitespaces)),
            let g = UInt8(parts[1].trimmingCharacters(in: .whitespaces)),
            let b = UInt8(parts[2].trimmingCharacters(in: .whitespaces))
      else { return nil }
      return (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0)
    }
    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard hex.count == 6,
          let value = UInt32(hex, radix: 16)
    else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8) & 0xFF) / 255.0
    let b = Double(value & 0xFF) / 255.0
    return (r, g, b)
  }
}
