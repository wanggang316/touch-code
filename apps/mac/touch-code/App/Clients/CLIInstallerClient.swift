import Foundation
import TouchCodeCore
import os.log
import tcKit

/// Idempotent, sudo-free installer for the `tc` CLI. Writes only under `$HOME`
/// (enforced by `HomeScopeGuard`) and never overwrites a file it did not create.
/// `probe()` is safe to call on view-appear; `install()` / `uninstall()` return
/// typed results that the Developer pane renders directly.
///
/// Design decisions (see `docs/design-docs/settings-developer.md`):
/// - Target directory is `~/.local/bin`, with a `tc` symlink and a peer `tcode`
///   symlink both pointing at the app-bundled binary.
/// - A foreign file at either symlink destination is reported as a collision;
///   we refuse to delete it and we refuse to overwrite it. The user renames it
///   or clears it themselves.
/// - PATH integration is only advisory — spec requires no rc-file edits in v1.
@MainActor
final class CLIInstallerClient {
  /// URLs that parameterise the installer. Tests override everything; production
  /// uses the defaults which resolve under the real `$HOME`.
  struct Paths: Equatable {
    var localBin: URL
    var tcSymlink: URL
    var tcodeSymlink: URL
    /// Bundled `tc` binary to symlink to. Resolved via `CLIBundleLocator`.
    /// `nil` when no bundled binary can be located — probe / install surface
    /// this as `.bundleMissing`.
    var bundledTcBinary: URL?
    /// `$HOME` root. Overridable so unit tests can run against a tmp directory.
    var homeDirectory: URL

    static var `default`: Paths {
      let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
      return Paths(
        localBin: localBin,
        tcSymlink: localBin.appendingPathComponent("tc", isDirectory: false),
        tcodeSymlink: localBin.appendingPathComponent("tcode", isDirectory: false),
        bundledTcBinary: try? CLIBundleLocator.locateBinary(),
        homeDirectory: home
      )
    }
  }

  /// Current state of the `tc` install under `~/.local/bin/`. Never persisted;
  /// the pane re-`probe()`s on appear.
  enum InstallStatus: Equatable {
    case unknown
    case notInstalled
    /// Both symlinks present and resolve to our bundled binary.
    case installed(at: URL, pointsToBundle: Bool)
    /// A file exists at `tcSymlink` but it is not our symlink. We never
    /// overwrite it.
    case collision(owner: URL)
    case failed(CLIInstallError, lastAttempt: Date?)
  }

  enum CLIInstallError: Error, Equatable {
    case bundleMissing(URL?)
    case directoryCreateFailed(URL, underlyingDescription: String)
    case destinationExistsNotOurs(URL)
    case destinationOutsideHome(URL)
    case symlinkFailed(URL, underlyingDescription: String)
    case uninstallFailed(URL, underlyingDescription: String)
  }

  private let paths: Paths
  private let fileSystem: SkillFileSystem
  private let pathLookup: () -> [URL]
  private let logger = Logger(subsystem: "com.touch-code.ui", category: "cli-installer")

  init(
    paths: Paths = .default,
    fileSystem: SkillFileSystem = RealSkillFileSystem(),
    pathLookup: @escaping () -> [URL] = CLIInstallerClient.defaultPathEntries
  ) {
    self.paths = paths
    self.fileSystem = fileSystem
    self.pathLookup = pathLookup
  }

  // MARK: - Probe

  /// Read-only state inspection. Never mutates, never throws; surfaces failures
  /// through `InstallStatus.failed` so the view renders them without special
  /// casing.
  func probe() -> InstallStatus {
    // Any escape from $HOME short-circuits with a dedicated error — even
    // probing a foreign path risks traversing attacker-controlled symlinks.
    if let escape = firstEscape(from: [paths.tcSymlink, paths.tcodeSymlink]) {
      return .failed(.destinationOutsideHome(escape), lastAttempt: nil)
    }

    let tcState = inspect(paths.tcSymlink)
    switch tcState {
    case .absent:
      return .notInstalled
    case .ourSymlink:
      return .installed(at: paths.tcSymlink, pointsToBundle: true)
    case .foreign:
      return .collision(owner: paths.tcSymlink)
    }
  }

  // MARK: - Install

  /// Creates `~/.local/bin` if missing, then symlinks `tc` and `tcode` at that
  /// directory's bundled-binary target. Idempotent — running twice from an
  /// installed state returns `.installed` without writing. Foreign files are
  /// left strictly alone and reported via `.collision`.
  func install() -> Result<InstallStatus, CLIInstallError> {
    guard let bundled = paths.bundledTcBinary else {
      return .failure(.bundleMissing(nil))
    }
    guard fileSystem.fileExists(atPath: bundled.path) else {
      return .failure(.bundleMissing(bundled))
    }
    if let escape = firstEscape(from: [paths.tcSymlink, paths.tcodeSymlink, paths.localBin]) {
      return .failure(.destinationOutsideHome(escape))
    }

    // Ensure parent dir exists. `withIntermediateDirectories: true` is idempotent
    // across existing directories; a failure is a real permission issue.
    if !fileSystem.isDirectory(atPath: paths.localBin.path) {
      do {
        try fileSystem.createDirectory(at: paths.localBin, withIntermediateDirectories: true)
      } catch {
        return .failure(.directoryCreateFailed(paths.localBin, underlyingDescription: "\(error)"))
      }
    }

    for destination in [paths.tcSymlink, paths.tcodeSymlink] {
      switch linkInPlace(at: destination, target: bundled) {
      case .success:
        continue
      case .failure(let error):
        logger.error(
          "install failed at \(destination.path, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        return .failure(error)
      }
    }

    logger.info("tc installed at \(self.paths.tcSymlink.path, privacy: .public)")
    return .success(.installed(at: paths.tcSymlink, pointsToBundle: true))
  }

  // MARK: - Uninstall

  /// Removes the `tc` and `tcode` symlinks iff they resolve to our bundled
  /// binary. Foreign files are never touched; `status` becomes `.collision` in
  /// that case.
  func uninstall() -> Result<InstallStatus, CLIInstallError> {
    if let escape = firstEscape(from: [paths.tcSymlink, paths.tcodeSymlink]) {
      return .failure(.destinationOutsideHome(escape))
    }

    for destination in [paths.tcSymlink, paths.tcodeSymlink] {
      let state = inspect(destination)
      switch state {
      case .absent:
        continue
      case .ourSymlink:
        do {
          try fileSystem.removeItem(at: destination)
        } catch {
          logger.error(
            "uninstall remove failed at \(destination.path, privacy: .public): \(String(describing: error), privacy: .public)"
          )
          return .failure(.uninstallFailed(destination, underlyingDescription: "\(error)"))
        }
      case .foreign:
        // Do not delete foreign files; surface the collision so the pane can
        // explain to the user why uninstall was refused at this path.
        return .success(.collision(owner: destination))
      }
    }

    logger.info("tc uninstalled at \(self.paths.tcSymlink.path, privacy: .public)")
    return .success(.notInstalled)
  }

  // MARK: - PATH advisory

  /// True when the canonicalised `paths.localBin` is one of the entries in the
  /// current process's `PATH`. Used only for the amber "not on PATH" advisory.
  func isLocalBinOnPath() -> Bool {
    let localBinPath = paths.localBin.standardizedFileURL.path
    return pathLookup().contains { $0.standardizedFileURL.path == localBinPath }
  }

  nonisolated static func defaultPathEntries() -> [URL] {
    let raw = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return
      raw
      .split(separator: ":", omittingEmptySubsequences: true)
      .map { String($0) }
      .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
  }

  // MARK: - Helpers

  /// Returns the first URL in `candidates` that escapes `$HOME`, or nil if
  /// every entry stays inside. Used by probe / install / uninstall so the
  /// HomeScopeGuard check is visible at every mutating entry point.
  private func firstEscape(from candidates: [URL]) -> URL? {
    candidates.first {
      !HomeScopeGuard.isInsideHome(
        $0, fileSystem: fileSystem, homeDirectory: paths.homeDirectory)
    }
  }

  private enum LinkState {
    case absent
    case ourSymlink
    case foreign
  }

  /// Classifies the destination path without mutating the filesystem. A path is
  /// "ours" iff it is a symlink and its resolved target (as absolute canonical
  /// path) equals the bundled binary's canonical path.
  private func inspect(_ destination: URL) -> LinkState {
    let attrs = try? fileSystem.attributesOfItem(atPath: destination.path)
    let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    if !isSymlink {
      // `fileExists` returns false for a dangling symlink, so if we got here
      // either the file really doesn't exist or it exists as a regular file /
      // directory. Treat regular files as foreign.
      if fileSystem.fileExists(atPath: destination.path) {
        return .foreign
      }
      if attrs != nil {
        // Non-symlink but stat-able (e.g. broken entry) — treat as foreign.
        return .foreign
      }
      return .absent
    }
    guard let rawTarget = try? fileSystem.destinationOfSymbolicLink(atPath: destination.path)
    else { return .foreign }
    let resolvedTarget: URL
    if rawTarget.hasPrefix("/") {
      resolvedTarget = URL(fileURLWithPath: rawTarget)
    } else {
      resolvedTarget = destination.deletingLastPathComponent().appendingPathComponent(rawTarget)
    }
    let resolvedPath = resolvedTarget.standardizedFileURL.path
    guard let bundled = paths.bundledTcBinary else { return .foreign }
    let bundledPath = bundled.standardizedFileURL.path
    return resolvedPath == bundledPath ? .ourSymlink : .foreign
  }

  /// Places a symlink at `destination` pointing at `target`. If the destination
  /// is already our symlink (via `inspect`) the call is a no-op. A foreign
  /// file/link at the destination produces `.destinationExistsNotOurs`; we
  /// never overwrite it.
  private func linkInPlace(at destination: URL, target: URL)
    -> Result<Void, CLIInstallError>
  {
    switch inspect(destination) {
    case .ourSymlink:
      return .success(())
    case .foreign:
      return .failure(.destinationExistsNotOurs(destination))
    case .absent:
      do {
        try fileSystem.createSymbolicLink(at: destination, withDestinationURL: target)
        return .success(())
      } catch {
        return .failure(.symlinkFailed(destination, underlyingDescription: "\(error)"))
      }
    }
  }
}

// MARK: - LocalizedError

extension CLIInstallerClient.CLIInstallError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .bundleMissing(let url):
      if let url {
        return "`tc` binary not found at \(url.path). Please reinstall touch-code."
      }
      return "`tc` binary not found in the app bundle. Please reinstall touch-code."
    case .directoryCreateFailed(let url, let description):
      return "Could not create \(url.path): \(description)"
    case .destinationExistsNotOurs(let url):
      return
        "Another file exists at \(url.path). Rename or remove it, then retry — touch-code will not overwrite a tool it did not install."
    case .destinationOutsideHome(let url):
      return "Refusing to write outside your home directory: \(url.path)"
    case .symlinkFailed(let url, let description):
      return "Could not link \(url.lastPathComponent): \(description)"
    case .uninstallFailed(let url, let description):
      return "Could not remove \(url.path): \(description)"
    }
  }
}
