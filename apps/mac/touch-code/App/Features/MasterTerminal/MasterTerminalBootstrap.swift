import Foundation
import os

/// Idempotent first-run setup for the Master Terminal user directory.
///
/// On first call: creates `~/.config/touch-code/master-terminal/`, writes
/// `AGENTS.md` from the bundled template, creates `CLAUDE.md` as a symlink
/// to `AGENTS.md`. Subsequent calls are no-ops if `AGENTS.md` already
/// exists — user edits are preserved.
public enum MasterTerminalBootstrap {
  /// `~/.config/touch-code/master-terminal/`. Stable across calls; depends only on `$HOME`.
  public static var userDirectory: URL {
    userDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
  }

  public static func userDirectory(homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("master-terminal", isDirectory: true)
  }

  /// Idempotent. See type doc.
  ///
  /// - Parameters:
  ///   - homeDirectory: override for tests; defaults to `$HOME`.
  ///   - bundle: source of the seed `AGENTS.md` template; defaults to `.main`.
  /// - Throws: `MasterTerminalBootstrapError.templateMissing` if the bundle
  ///   does not contain the seed resource. Any underlying `FileManager` error
  ///   is rethrown verbatim.
  public static func ensureUserDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundle: Bundle = .main
  ) throws {
    let dir = userDirectory(homeDirectory: homeDirectory)
    let agentsURL = dir.appendingPathComponent("AGENTS.md", isDirectory: false)
    let claudeURL = dir.appendingPathComponent("CLAUDE.md", isDirectory: false)

    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    // Seed AGENTS.md only if absent. Preserves user edits across launches.
    if !fm.fileExists(atPath: agentsURL.path) {
      guard
        let templateURL = bundle.url(
          forResource: "MasterTerminalAGENTS",
          withExtension: "md"
        )
      else {
        throw MasterTerminalBootstrapError.templateMissing
      }
      let contents = try Data(contentsOf: templateURL)
      try contents.write(to: agentsURL, options: .atomic)
    }

    // Create CLAUDE.md → AGENTS.md symlink. If a non-symlink already exists
    // (regular file, directory, or wrong-target symlink), leave it alone and
    // log — overwriting could destroy user content.
    let claudeAttrs = try? fm.attributesOfItem(atPath: claudeURL.path)
    if claudeAttrs == nil {
      // Path does not exist (or is a broken symlink). Create the symlink.
      // FileManager.createSymbolicLink fails if any item exists at the path,
      // including a dangling symlink, so explicitly remove that case first.
      // Use the path-based API: passing a URL would expand "AGENTS.md" against
      // the process cwd and bake an absolute target into the symlink.
      if (try? fm.destinationOfSymbolicLink(atPath: claudeURL.path)) != nil {
        try? fm.removeItem(at: claudeURL)
      }
      try fm.createSymbolicLink(
        atPath: claudeURL.path,
        withDestinationPath: "AGENTS.md"
      )
    } else if (claudeAttrs?[.type] as? FileAttributeType) != .typeSymbolicLink {
      Logger.masterTerminal.warning(
        "CLAUDE.md exists but is not a symlink; leaving as-is at \(claudeURL.path, privacy: .public)"
      )
    } else {
      // Existing symlink: trust it. Even if it points elsewhere, that is the
      // user's choice. Do not touch.
    }
  }
}

public enum MasterTerminalBootstrapError: Error, Equatable {
  case templateMissing
}

extension Logger {
  fileprivate static let masterTerminal = Logger(
    subsystem: "com.gumpw.touch-agent-mac",
    category: "master-terminal"
  )
}
