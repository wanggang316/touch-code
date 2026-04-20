import CryptoKit
import Foundation

/// Install mode selected by `tc skill install`. `.copy` materialises files at the
/// destination; `.symlink` creates a symlink to the bundled `touch-code-skill/`.
public enum InstallMode: String, Codable, Sendable { case copy, symlink }

public struct InstallOptions: Sendable {
  public var force: Bool
  public var dryRun: Bool
  public var now: Date
  /// When true, `install` refuses to write outside `NSHomeDirectory()`. CLI leaves this on;
  /// unit tests that install into a temp dir flip it off.
  public var enforceHomeScope: Bool

  public init(
    force: Bool = false,
    dryRun: Bool = false,
    now: Date = Date(),
    enforceHomeScope: Bool = true
  ) {
    self.force = force
    self.dryRun = dryRun
    self.now = now
    self.enforceHomeScope = enforceHomeScope
  }
}

public enum InstallResultKind: String, Sendable, Equatable {
  case installed
  case reinstalled
  case noop
  case dryRun
}

public struct InstallResult: Equatable, Sendable {
  public let destination: URL
  public let marker: InstalledSkillMarker
  public let filesWritten: [URL]
  public let kind: InstallResultKind
}

/// Persisted record of a completed install. Version-gated; readers abort on unknown
/// top-level `version`-like fields, following the architecture's persistence invariant.
public struct InstalledSkillMarker: Codable, Equatable, Sendable {
  public var version: String
  public var installedAt: Date
  public var source: InstallMode
  public var bundlePath: String
  public var bundleSha256: String

  public init(
    version: String,
    installedAt: Date,
    source: InstallMode,
    bundlePath: String,
    bundleSha256: String
  ) {
    self.version = version
    self.installedAt = installedAt
    self.source = source
    self.bundlePath = bundlePath
    self.bundleSha256 = bundleSha256
  }
}

public enum InstallError: Error, Equatable, Sendable {
  case bundleMissing(URL)
  case destinationExistsNoMarker(URL)
  case destinationExistsLocalEdits(URL)
  case destinationOutsideHome(URL)
  case symlinkRequiresAbsoluteBundlePath(URL)
  case versionFileMissing(URL)
}

/// The filename written inside a copy-mode destination.
public let markerFilename = ".touch-code-skill.json"

/// Installs, uninstalls, and hashes the bundled `touch-code-skill/` package. Pure file
/// I/O against an injectable `SkillFileSystem`. No network, no agent coupling, no skill
/// content parsing beyond reading `VERSION`.
public struct SkillInstaller: Sendable {
  public let bundleURL: URL
  public let fileSystem: SkillFileSystem

  public init(bundleURL: URL, fileSystem: SkillFileSystem = RealSkillFileSystem()) {
    self.bundleURL = bundleURL
    self.fileSystem = fileSystem
  }

  // MARK: - Install

  public func install(
    to destination: URL,
    mode: InstallMode,
    options: InstallOptions = InstallOptions()
  ) throws -> InstallResult {
    try ensureBundle()
    try ensureHomeScope(destination, options: options)

    switch mode {
    case .copy:    return try installCopy(to: destination, options: options)
    case .symlink: return try installSymlink(to: destination, options: options)
    }
  }

  public func uninstall(at destination: URL) throws {
    let markerURL = markerURL(for: destination, mode: detectMode(destination))
    if fileSystem.fileExists(atPath: destination.path) {
      try fileSystem.removeItem(at: destination)
    }
    if fileSystem.fileExists(atPath: markerURL.path) {
      try fileSystem.removeItem(at: markerURL)
    }
  }

  /// Reads the install marker, transparently resolving the copy vs. symlink sidecar path
  /// per DEC-1. Returns nil if nothing is installed.
  public func readMarker(at destination: URL) throws -> InstalledSkillMarker? {
    let mode = detectMode(destination)
    let url = markerURL(for: destination, mode: mode)
    guard fileSystem.fileExists(atPath: url.path),
          let data = fileSystem.contents(atPath: url.path)
    else {
      return nil
    }
    return try Self.decoder.decode(InstalledSkillMarker.self, from: data)
  }

  public func currentBundleSha256() throws -> String {
    try directorySha256(at: bundleURL)
  }

  /// SHA-256 of `<rel>\0<mode>\0<size>\0<bytes>\0` for each regular file in sorted path
  /// order. Deterministic across machines and FS layouts. Symlinks and non-regular files
  /// are rejected; the bundle contains only regular files.
  public func directorySha256(at url: URL) throws -> String {
    var hasher = SHA256()
    var paths = try fileSystem.subpathsOfDirectory(at: url)
    paths.sort() // POSIX bytewise sort
    for rel in paths where !rel.hasSuffix("/.DS_Store") && rel != ".DS_Store" {
      let absolute = url.appendingPathComponent(rel)
      // Skip marker file if present inside the destination we're hashing (it would
      // change the hash on every reinstall otherwise).
      if rel == markerFilename { continue }
      let attrs = try fileSystem.attributesOfItem(atPath: absolute.path)
      let type = attrs[.type] as? FileAttributeType ?? .typeUnknown
      switch type {
      case .typeDirectory: continue
      case .typeRegular: break
      default: continue
      }
      guard let data = fileSystem.contents(atPath: absolute.path) else {
        throw InstallError.bundleMissing(absolute)
      }
      let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
      let size = (attrs[.size] as? NSNumber)?.intValue ?? data.count

      hasher.update(data: Data(rel.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: Data(String(mode, radix: 8).utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: Data(String(size).utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: data)
      hasher.update(data: Data([0]))
    }
    return hasher.finalize().hex
  }

  public func readBundledVersion() throws -> String {
    let versionURL = bundleURL.appendingPathComponent("VERSION")
    guard let data = fileSystem.contents(atPath: versionURL.path) else {
      throw InstallError.versionFileMissing(versionURL)
    }
    let text = String(bytes: data, encoding: .utf8) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Internal

  private func ensureBundle() throws {
    guard fileSystem.isDirectory(atPath: bundleURL.path) else {
      throw InstallError.bundleMissing(bundleURL)
    }
  }

  private func ensureHomeScope(_ destination: URL, options: InstallOptions) throws {
    guard options.enforceHomeScope else { return }
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
    let dest = destination.standardizedFileURL
    if !dest.path.hasPrefix(home.path + "/") && dest.path != home.path {
      throw InstallError.destinationOutsideHome(destination)
    }
  }

  private func installCopy(to destination: URL, options: InstallOptions) throws -> InstallResult {
    let version = try readBundledVersion()
    let bundleHash = try currentBundleSha256()

    // Idempotence check: same version + same bundle hash + destination-tree hash matches.
    if let existing = try readMarker(at: destination),
       existing.version == version,
       existing.bundleSha256 == bundleHash {
      let destinationHash = (try? directorySha256(at: destination)) ?? ""
      if destinationHash == bundleHash {
        return InstallResult(
          destination: destination,
          marker: existing,
          filesWritten: [],
          kind: .noop
        )
      }
      if !options.force {
        throw InstallError.destinationExistsLocalEdits(destination)
      }
    }

    if fileSystem.fileExists(atPath: destination.path) {
      if (try readMarker(at: destination)) == nil, !options.force {
        throw InstallError.destinationExistsNoMarker(destination)
      }
      if options.dryRun == false {
        try fileSystem.removeItem(at: destination)
      }
    }

    let marker = InstalledSkillMarker(
      version: version,
      installedAt: options.now,
      source: .copy,
      bundlePath: bundleURL.path,
      bundleSha256: bundleHash
    )

    if options.dryRun {
      let planned = try plannedCopyFiles(destination: destination)
      return InstallResult(
        destination: destination,
        marker: marker,
        filesWritten: planned,
        kind: .dryRun
      )
    }

    try ensureParentDir(of: destination)
    try fileSystem.copyItem(at: bundleURL, to: destination)
    let written = try plannedCopyFiles(destination: destination)
    try writeMarker(marker, to: markerURL(for: destination, mode: .copy))

    let kind: InstallResultKind = fileSystem.fileExists(atPath: destination.path)
      ? .reinstalled : .installed
    _ = kind // always `.installed` when we reach here because we removed any existing dir
    return InstallResult(
      destination: destination,
      marker: marker,
      filesWritten: written,
      kind: .installed
    )
  }

  private func installSymlink(
    to destination: URL,
    options: InstallOptions
  ) throws -> InstallResult {
    guard bundleURL.path.hasPrefix("/") else {
      throw InstallError.symlinkRequiresAbsoluteBundlePath(bundleURL)
    }
    let version = try readBundledVersion()
    let bundleHash = try currentBundleSha256()
    let marker = InstalledSkillMarker(
      version: version,
      installedAt: options.now,
      source: .symlink,
      bundlePath: bundleURL.path,
      bundleSha256: bundleHash
    )

    if options.dryRun {
      return InstallResult(
        destination: destination,
        marker: marker,
        filesWritten: [destination],
        kind: .dryRun
      )
    }

    if fileSystem.fileExists(atPath: destination.path) {
      // Existing install — only tolerate if same-version / same-bundle or --force.
      if let existing = try readMarker(at: destination),
         existing.version == version,
         existing.bundleSha256 == bundleHash,
         existing.source == .symlink {
        return InstallResult(
          destination: destination,
          marker: existing,
          filesWritten: [],
          kind: .noop
        )
      }
      if (try readMarker(at: destination)) == nil, !options.force {
        throw InstallError.destinationExistsNoMarker(destination)
      }
      try fileSystem.removeItem(at: destination)
    }

    try ensureParentDir(of: destination)
    try fileSystem.createSymbolicLink(at: destination, withDestinationURL: bundleURL)
    try writeMarker(marker, to: markerURL(for: destination, mode: .symlink))
    return InstallResult(
      destination: destination,
      marker: marker,
      filesWritten: [destination],
      kind: .installed
    )
  }

  // MARK: - Marker helpers

  /// Returns the path where the install marker lives for `destination` under `mode`.
  /// - `.copy` → `<destination>/.touch-code-skill.json` (inside the installed dir).
  /// - `.symlink` → `<destination>.marker.json` (sibling of the symlink). See DEC-1.
  private func markerURL(for destination: URL, mode: InstallMode) -> URL {
    switch mode {
    case .copy:
      return destination.appendingPathComponent(markerFilename)
    case .symlink:
      let name = destination.lastPathComponent + ".marker.json"
      return destination.deletingLastPathComponent().appendingPathComponent(name)
    }
  }

  /// Infers install mode by inspecting the destination: if it is a symlink, use `.symlink`;
  /// otherwise assume `.copy`. If nothing is installed, `.copy` is the safe default — it
  /// makes `readMarker` look inside the directory (no match; returns nil).
  private func detectMode(_ destination: URL) -> InstallMode {
    let attrs = try? fileSystem.attributesOfItem(atPath: destination.path)
    if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
      return .symlink
    }
    // When nothing is installed, `detectMode` is called by readMarker; the sibling file
    // could exist even if the symlink itself was cleaned up, so check the sidecar too.
    let siblingName = destination.lastPathComponent + ".marker.json"
    let sibling = destination.deletingLastPathComponent().appendingPathComponent(siblingName)
    if fileSystem.fileExists(atPath: sibling.path) {
      return .symlink
    }
    return .copy
  }

  private func writeMarker(_ marker: InstalledSkillMarker, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(marker)
    try fileSystem.writeData(data, to: url)
  }

  private func plannedCopyFiles(destination: URL) throws -> [URL] {
    let paths = (try fileSystem.subpathsOfDirectory(at: bundleURL)).sorted()
    return paths.map { destination.appendingPathComponent($0) }
  }

  private func ensureParentDir(of destination: URL) throws {
    let parent = destination.deletingLastPathComponent()
    if !fileSystem.fileExists(atPath: parent.path) {
      try fileSystem.createDirectory(at: parent, withIntermediateDirectories: true)
    }
  }

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}

extension SHA256.Digest {
  fileprivate var hex: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
