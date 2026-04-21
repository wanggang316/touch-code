import Foundation
import Testing

@testable import tcKit

struct SkillInstallerTests {
  // MARK: - Copy mode

  @Test
  func installCopyProducesTreeAndMarker() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()

    let result = try installer.install(
      to: fixture.appendingPathComponent("touch-code"),
      mode: .copy,
      options: Self.testOptions()
    )

    #expect(result.kind == .installed)
    let skill = fixture.appendingPathComponent("touch-code/SKILL.md")
    #expect(FileManager.default.fileExists(atPath: skill.path))
    let markerURL = fixture.appendingPathComponent("touch-code/\(markerFilename)")
    #expect(FileManager.default.fileExists(atPath: markerURL.path))

    // Marker bundleSha256 must match currentBundleSha256().
    let bundleHash = try installer.currentBundleSha256()
    let marker = try installer.readMarker(at: fixture.appendingPathComponent("touch-code"))
    #expect(marker?.bundleSha256 == bundleHash)
    #expect(marker?.source == .copy)
  }

  @Test
  func reinstallSameVersionNoEditsIsNoop() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")

    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    let second = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    #expect(second.kind == .noop)
    #expect(second.filesWritten.isEmpty)
  }

  @Test
  func reinstallWithEditsThrowsWithoutForce() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")

    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    // Edit a file inside the installed tree.
    let edited = dest.appendingPathComponent("SKILL.md")
    try Data("LOCAL EDIT".utf8).write(to: edited)

    var error: InstallError?
    do {
      _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    } catch let e as InstallError {
      error = e
    }
    #expect(error == .destinationExistsLocalEdits(dest))
  }

  @Test
  func forceReinstallReplacesEditedTreeFully() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")

    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    let edited = dest.appendingPathComponent("SKILL.md")
    try Data("LOCAL EDIT".utf8).write(to: edited)

    let forced = try installer.install(
      to: dest,
      mode: .copy,
      options: Self.testOptions(force: true)
    )
    #expect(forced.kind == .reinstalled)
    // The edited content is gone — re-read shows the bundled SKILL.md bytes.
    let restored = try String(contentsOf: edited, encoding: .utf8)
    #expect(!restored.contains("LOCAL EDIT"))
    // Marker bundleSha256 matches current bundle hash (tree was fully re-copied).
    let bundleHash = try installer.currentBundleSha256()
    #expect(forced.marker.bundleSha256 == bundleHash)
  }

  @Test
  func installIntoExistingNonSkillDirThrowsWithoutForce() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try Data("stranger".utf8).write(to: dest.appendingPathComponent("foreign.txt"))
    let installer = Self.installer()

    var error: InstallError?
    do {
      _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    } catch let e as InstallError {
      error = e
    }
    #expect(error == .destinationExistsNoMarker(dest))
  }

  @Test
  func installOutsideHomeThrowsWhenEnforced() throws {
    let installer = Self.installer()
    let dest = URL(fileURLWithPath: "/tmp/tc-skill-outside-home-\(UUID().uuidString)")
    var error: InstallError?
    do {
      _ = try installer.install(
        to: dest,
        mode: .copy,
        options: InstallOptions(enforceHomeScope: true)
      )
    } catch let e as InstallError {
      error = e
    }
    #expect(error == .destinationOutsideHome(dest))
  }

  // MARK: - Dry run

  @Test
  func dryRunWritesNothing() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    let installer = Self.installer()

    let result = try installer.install(
      to: dest,
      mode: .copy,
      options: Self.testOptions(dryRun: true)
    )
    #expect(result.kind == .dryRun)
    #expect(!FileManager.default.fileExists(atPath: dest.path))
    #expect(!result.filesWritten.isEmpty) // we project the planned file list
  }

  // MARK: - Uninstall

  @Test
  func uninstallRemovesTreeAndMarkerAndIsIdempotent() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    let installer = Self.installer()
    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())

    try installer.uninstall(at: dest)
    #expect(!FileManager.default.fileExists(atPath: dest.path))

    // Second uninstall on clean state must not throw.
    try installer.uninstall(at: dest)
  }

  // MARK: - Symlink mode

  @Test
  func symlinkInstallCreatesLinkAndSidecarMarker() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    let installer = Self.installer()

    let result = try installer.install(
      to: dest,
      mode: .symlink,
      options: Self.testOptions()
    )
    #expect(result.marker.source == .symlink)
    // Destination is a symbolic link.
    let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
    #expect((attrs[.type] as? FileAttributeType) == .typeSymbolicLink)
    // Sidecar marker is written at <dest>.marker.json per DEC-1.
    let sidecar = fixture.appendingPathComponent("touch-code.marker.json")
    #expect(FileManager.default.fileExists(atPath: sidecar.path))

    // readMarker transparently finds the sidecar.
    let marker = try installer.readMarker(at: dest)
    #expect(marker?.source == .symlink)
  }

  @Test
  func readMarkerReturnsNilWhenNothingInstalled() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")
    #expect(try installer.readMarker(at: dest) == nil)
  }

  @Test
  func readMarkerIgnoresStraySidecarWhenDestIsNotSymlink() throws {
    // Install a copy-mode skill, then drop an unrelated `touch-code.marker.json` next to
    // it. readMarker must return the inside-dir marker (source=.copy), NOT the stray
    // sidecar. Regression guard against over-permissive detectMode sidecar probing.
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")
    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())

    let strayPayload = """
      {
        "version": "99.99.99",
        "installedAt": "2000-01-01T00:00:00Z",
        "source": "symlink",
        "bundlePath": "/nowhere",
        "bundleSha256": "deadbeef"
      }
      """
    let stray = fixture.appendingPathComponent("touch-code.marker.json")
    try Data(strayPayload.utf8).write(to: stray)

    let marker = try installer.readMarker(at: dest)
    #expect(marker?.source == .copy)
    #expect(marker?.version != "99.99.99") // did NOT read the stray sidecar
  }

  @Test
  func uninstallCleansBothMarkerLocations() throws {
    // Simulate a mixed-mode residue: directory + stray sidecar both present. Uninstall
    // must sweep both.
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")
    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())

    let sidecar = fixture.appendingPathComponent("touch-code.marker.json")
    try Data("{}".utf8).write(to: sidecar)

    try installer.uninstall(at: dest)
    #expect(!FileManager.default.fileExists(atPath: dest.path))
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
  }

  @Test
  func reinstallWhenDestPreExistedReportsReinstalledKind() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")

    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())
    // Simulate drift so the idempotence fast-path doesn't short-circuit to .noop.
    try Data("LOCAL EDIT".utf8).write(to: dest.appendingPathComponent("SKILL.md"))

    let result = try installer.install(
      to: dest,
      mode: .copy,
      options: Self.testOptions(force: true)
    )
    #expect(result.kind == .reinstalled)
  }

  // MARK: - Error surfaces

  @Test
  func installErrorsExposeLocalizedDescriptions() throws {
    let url = URL(fileURLWithPath: "/tmp/example")
    let cases: [InstallError] = [
      .bundleMissing(url),
      .destinationExistsNoMarker(url),
      .destinationExistsLocalEdits(url),
      .destinationOutsideHome(url),
      .symlinkRequiresAbsoluteBundlePath(url),
      .versionFileMissing(url),
    ]
    for error in cases {
      let description = error.errorDescription ?? ""
      #expect(!description.isEmpty, "missing errorDescription for \(error)")
      #expect(!description.contains("The operation couldn't be completed"))
    }
  }

  // MARK: - Hash determinism

  @Test
  func bundleSha256IsDeterministicAcrossInvocations() throws {
    let installer = Self.installer()
    let h1 = try installer.currentBundleSha256()
    let h2 = try installer.currentBundleSha256()
    let h3 = try installer.currentBundleSha256()
    #expect(h1 == h2)
    #expect(h2 == h3)
    #expect(h1.count == 64) // sha256 hex length
  }

  @Test
  func directorySha256ExcludesMarkerFile() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let installer = Self.installer()
    let dest = fixture.appendingPathComponent("touch-code")
    _ = try installer.install(to: dest, mode: .copy, options: Self.testOptions())

    // The installed tree contains a marker; hashing it must still equal the bundle hash,
    // because `directorySha256` skips the marker filename.
    let bundleHash = try installer.currentBundleSha256()
    let destHash = try installer.directorySha256(at: dest)
    #expect(bundleHash == destHash)
  }

  @Test
  func versionFileReadsBundledSemver() throws {
    let installer = Self.installer()
    let version = try installer.readBundledVersion()
    #expect(version == "0.1.0")
  }

  // MARK: - Helpers

  /// Build an installer pointing at the in-repo `touch-code-skill/` fixture.
  static func installer() -> SkillInstaller {
    SkillInstaller(bundleURL: bundleFixture())
  }

  static func bundleFixture() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // tcTests
      .deletingLastPathComponent() // mac
      .deletingLastPathComponent() // apps
      .deletingLastPathComponent() // repo root
      .appendingPathComponent("skills/touch-code-cli")
  }

  /// A tempdir under $HOME so the HOME-scope check is satisfied by default.
  static func tempDir() -> URL {
    let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".touch-code-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  static func testOptions(
    force: Bool = false,
    dryRun: Bool = false,
    now: Date = Date(timeIntervalSince1970: 1_713_610_000)
  ) -> InstallOptions {
    InstallOptions(force: force, dryRun: dryRun, now: now, enforceHomeScope: true)
  }
}
