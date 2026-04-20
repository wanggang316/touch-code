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
///
/// Naming boundary: the `source` field is the *private* schema name for the install
/// mode. Public-facing JSON emitted by `tc skill status --json` (M4a) renames it to
/// `installMode` to match `agents.json`'s public key. Keeping the names separate avoids
/// an on-disk schema rename if the public surface later adds modes the marker shouldn't
/// persist (e.g. a future `.tracked` mode used only for reporting).
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

extension InstallError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .bundleMissing(let url):
      return "Skill bundle missing at \(url.path). Rebuild touch-code.app or check `tc skill bundle-path`."
    case .destinationExistsNoMarker(let url):
      return "\(url.path) exists but was not installed by tc. Re-run with --force to overwrite."
    case .destinationExistsLocalEdits(let url):
      return "\(url.path) has local edits since last install. Re-run with --force to discard them."
    case .destinationOutsideHome(let url):
      return "Refusing to install outside $HOME: \(url.path)"
    case .symlinkRequiresAbsoluteBundlePath(let url):
      return "--link requires an absolute bundle path; got \(url.path)"
    case .versionFileMissing(let url):
      return "Bundled skill is missing its VERSION file at \(url.path)."
    }
  }
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

  /// Removes the installed entity (directory or symlink) and *both* potential marker
  /// locations — the inside-dir copy marker and the sidecar symlink marker — so partial
  /// installs left over from crashes, manual edits, or mode switches are fully cleaned.
  /// Idempotent: calling on an already-clean destination is a no-op.
  public func uninstall(at destination: URL) throws {
    if fileSystem.fileExists(atPath: destination.path) {
      try fileSystem.removeItem(at: destination)
    }
    let copyMarker = markerURL(for: destination, mode: .copy)
    if fileSystem.fileExists(atPath: copyMarker.path) {
      try fileSystem.removeItem(at: copyMarker)
    }
    let symlinkMarker = markerURL(for: destination, mode: .symlink)
    if fileSystem.fileExists(atPath: symlinkMarker.path) {
      try fileSystem.removeItem(at: symlinkMarker)
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

  /// SHA-256 of `<rel>\0<size>\0<bytes>\0` for each regular file in sorted path order.
  /// Deterministic across machines, FS layouts, and umask/exec-bit variations —
  /// `posixPermissions` is deliberately excluded from the digest because `FileManager`'s
  /// `copyItem` does not uniformly preserve exec bits across file-system boundaries
  /// (APFS → tmpfs and back again drops the bit). Hashing mode would produce false-
  /// positive drift on every reinstall with an executable in the tree. Content is the
  /// only thing we need to protect against local edits, and content is what we hash.
  public func directorySha256(at url: URL) throws -> String {
    var hasher = SHA256()
    let paths = try fileSystem.subpathsOfDirectory(at: url) // contract: sorted ascending
    for rel in paths {
      if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
      if rel == markerFilename { continue } // install marker excluded from its own hash
      let absolute = url.appendingPathComponent(rel)
      let attrs = try fileSystem.attributesOfItem(atPath: absolute.path)
      let type = attrs[.type] as? FileAttributeType ?? .typeUnknown
      guard type == .typeRegular else { continue } // directories and symlinks skipped
      guard let data = fileSystem.contents(atPath: absolute.path) else {
        throw InstallError.bundleMissing(absolute)
      }
      let size = (attrs[.size] as? NSNumber)?.intValue ?? data.count

      hasher.update(data: Data(rel.utf8))
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

  /// HOME-scope enforcement applies to `destination` only — `bundleURL` is read-only
  /// content owned by the app (typically under `/Applications/.../Resources/`), so
  /// pinning it inside HOME would prevent normal operation. DEC-4 covers destination-
  /// side enforcement; this asymmetry is intentional.
  private func ensureHomeScope(_ destination: URL, options: InstallOptions) throws {
    guard options.enforceHomeScope else { return }
    let home = URL(fileURLWithPath: NSHomeDirectory())
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let dest = destination
      .standardizedFileURL
      .resolvingSymlinksInPath()
    if !dest.path.hasPrefix(home.path + "/") && dest.path != home.path {
      throw InstallError.destinationOutsideHome(destination)
    }
  }

  private func installCopy(to destination: URL, options: InstallOptions) throws -> InstallResult {
    let version = try readBundledVersion()
    let bundleHash = try currentBundleSha256()
    let destPreExisted = fileSystem.fileExists(atPath: destination.path)

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

    if destPreExisted {
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

    return InstallResult(
      destination: destination,
      marker: marker,
      filesWritten: written,
      kind: destPreExisted ? .reinstalled : .installed
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

  /// Infers install mode by checking whether `destination` itself is a symlink. Anything
  /// else — regular dir, missing entry, file — is treated as `.copy`. The sidecar sibling
  /// is **not** probed here: a stray `<foo>.marker.json` next to an unrelated `<foo>/`
  /// directory must not cause `readMarker` to pick up foreign JSON.
  private func detectMode(_ destination: URL) -> InstallMode {
    let attrs = try? fileSystem.attributesOfItem(atPath: destination.path)
    if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
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

  /// Projects the list of regular-file paths that a copy install would write under
  /// `destination`, using the same predicate as `directorySha256` (regular files only,
  /// no directories, no `.DS_Store`, no install marker). This is what populates
  /// `InstallResult.filesWritten` for dry-run reporting.
  private func plannedCopyFiles(destination: URL) throws -> [URL] {
    let paths = try fileSystem.subpathsOfDirectory(at: bundleURL) // contract: sorted
    var urls: [URL] = []
    urls.reserveCapacity(paths.count)
    for rel in paths {
      if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
      if rel == markerFilename { continue }
      let absolute = bundleURL.appendingPathComponent(rel)
      guard let attrs = try? fileSystem.attributesOfItem(atPath: absolute.path),
            (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
      urls.append(destination.appendingPathComponent(rel))
    }
    return urls
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
