import Foundation
import Testing
import tcKit

@testable import touch_code

/// Covers install / uninstall / probe state transitions plus the HomeScopeGuard
/// escape rejection. Uses a real filesystem rooted at a fresh tmp directory so
/// the symlink-introspection paths exercise the same code that runs in
/// production.
@MainActor
@Suite("CLIInstallerClient")
struct CLIInstallerClientTests {
  // MARK: - Fixture helpers

  private final class TempHome {
    let root: URL
    let bundledTc: URL

    init() throws {
      let root = FileManager.default.temporaryDirectory.appending(
        component: "tc-installer-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let bundleDir = root.appending(component: "Bundle", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
      let binary = bundleDir.appending(component: "tc", directoryHint: .notDirectory)
      try Data("#!/bin/sh\n".utf8).write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
      self.root = root
      self.bundledTc = binary
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }

    func paths(overridingLocalBin: URL? = nil) -> CLIInstallerClient.Paths {
      let localBin = overridingLocalBin ?? root.appending(component: ".local/bin", directoryHint: .isDirectory)
      return CLIInstallerClient.Paths(
        localBin: localBin,
        tcSymlink: localBin.appending(component: "tc", directoryHint: .notDirectory),
        tcodeSymlink: localBin.appending(component: "tcode", directoryHint: .notDirectory),
        bundledTcBinary: bundledTc,
        homeDirectory: root
      )
    }
  }

  private func makeClient(
    paths: CLIInstallerClient.Paths,
    fileSystem: SkillFileSystem = RealSkillFileSystem()
  ) -> CLIInstallerClient {
    CLIInstallerClient(paths: paths, fileSystem: fileSystem, pathLookup: { [] })
  }

  private func assertInstalled(_ status: CLIInstallerClient.InstallStatus) {
    if case .installed(_, let pointsToBundle) = status {
      #expect(pointsToBundle == true)
    } else {
      Issue.record("Expected .installed, got \(status)")
    }
  }

  // MARK: - Probe

  @Test
  func probe_freshFilesystem_returnsNotInstalled() throws {
    let home = try TempHome()
    let client = makeClient(paths: home.paths())

    #expect(client.probe() == .notInstalled)
  }

  // MARK: - Install

  @Test
  func install_createsBothSymlinks_statusBecomesInstalled() throws {
    let home = try TempHome()
    let paths = home.paths()
    let client = makeClient(paths: paths)

    let result = client.install()

    switch result {
    case .success(let status):
      assertInstalled(status)
    case .failure(let error):
      Issue.record("Install failed: \(error)")
    }
    #expect(FileManager.default.fileExists(atPath: paths.tcSymlink.path))
    #expect(FileManager.default.fileExists(atPath: paths.tcodeSymlink.path))
    let tcTarget = try FileManager.default.destinationOfSymbolicLink(atPath: paths.tcSymlink.path)
    #expect(URL(fileURLWithPath: tcTarget).standardizedFileURL == home.bundledTc.standardizedFileURL)
    let tcodeTarget = try FileManager.default.destinationOfSymbolicLink(atPath: paths.tcodeSymlink.path)
    #expect(URL(fileURLWithPath: tcodeTarget).standardizedFileURL == home.bundledTc.standardizedFileURL)
  }

  @Test
  func install_isIdempotent() throws {
    let home = try TempHome()
    let paths = home.paths()
    let client = makeClient(paths: paths)

    _ = client.install()
    let second = client.install()

    switch second {
    case .success(let status): assertInstalled(status)
    case .failure(let error): Issue.record("Second install failed: \(error)")
    }
    // Status is stable and no duplicate symlinks were created.
    assertInstalled(client.probe())
  }

  @Test
  func install_whenDestExistsAndIsForeign_returnsDestinationExistsNotOurs() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createDirectory(at: paths.localBin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let client = makeClient(paths: paths)

    let result = client.install()

    if case .failure(.destinationExistsNotOurs(let url)) = result {
      #expect(url == paths.tcSymlink)
    } else {
      Issue.record("Expected .destinationExistsNotOurs, got \(result)")
    }
    // And the foreign file is untouched.
    let contents = try String(contentsOf: paths.tcSymlink, encoding: .utf8)
    #expect(contents.contains("foreign"))
  }

  // MARK: - Uninstall

  @Test
  func uninstall_whenInstalledByUs_removesBothAndReturnsNotInstalled() throws {
    let home = try TempHome()
    let paths = home.paths()
    let client = makeClient(paths: paths)
    _ = client.install()

    let result = client.uninstall()

    #expect(result == .success(.notInstalled))
    #expect(!FileManager.default.fileExists(atPath: paths.tcSymlink.path))
    #expect(!FileManager.default.fileExists(atPath: paths.tcodeSymlink.path))
  }

  @Test
  func uninstall_whenForeignPresent_reportsCollisionAndRefuses() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createDirectory(at: paths.localBin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let client = makeClient(paths: paths)

    let result = client.uninstall()

    if case .success(.collision(let owner)) = result {
      #expect(owner == paths.tcSymlink)
    } else {
      Issue.record("Expected .collision, got \(result)")
    }
    // File remains.
    #expect(FileManager.default.fileExists(atPath: paths.tcSymlink.path))
  }

  // MARK: - Retry after failure

  /// `SkillFileSystem` fake that fails `createSymbolicLink` a fixed number of
  /// times before delegating to the real filesystem. Covers the "failed, then
  /// retry succeeds" flow without relying on OS-level disk faults.
  private final class FlakySymlinkFileSystem: SkillFileSystem, @unchecked Sendable {
    private let real = RealSkillFileSystem()
    private var remainingFailures: Int

    init(failCount: Int) { self.remainingFailures = failCount }

    func fileExists(atPath path: String) -> Bool { real.fileExists(atPath: path) }
    func isDirectory(atPath path: String) -> Bool { real.isDirectory(atPath: path) }
    func createDirectory(at url: URL, withIntermediateDirectories flag: Bool) throws {
      try real.createDirectory(at: url, withIntermediateDirectories: flag)
    }
    func copyItem(at src: URL, to dst: URL) throws { try real.copyItem(at: src, to: dst) }
    func removeItem(at url: URL) throws { try real.removeItem(at: url) }
    func createSymbolicLink(at url: URL, withDestinationURL dst: URL) throws {
      if remainingFailures > 0 {
        remainingFailures -= 1
        throw NSError(domain: "FakeFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected symlink failure"])
      }
      try real.createSymbolicLink(at: url, withDestinationURL: dst)
    }
    func destinationOfSymbolicLink(atPath path: String) throws -> String {
      try real.destinationOfSymbolicLink(atPath: path)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
      try real.attributesOfItem(atPath: path)
    }
    func contents(atPath path: String) -> Data? { real.contents(atPath: path) }
    func subpathsOfDirectory(at url: URL) throws -> [String] {
      try real.subpathsOfDirectory(at: url)
    }
    func writeData(_ data: Data, to url: URL) throws { try real.writeData(data, to: url) }
  }

  @Test
  func install_failure_thenRetry_succeeds() throws {
    let home = try TempHome()
    let paths = home.paths()
    let flaky = FlakySymlinkFileSystem(failCount: 1)
    let client = makeClient(paths: paths, fileSystem: flaky)

    let first = client.install()
    if case .failure(.symlinkFailed) = first {
      // expected
    } else {
      Issue.record("Expected .symlinkFailed on first attempt, got \(first)")
    }

    let second = client.install()
    switch second {
    case .success(let status): assertInstalled(status)
    case .failure(let error): Issue.record("Retry failed: \(error)")
    }
  }

  // MARK: - HomeScopeGuard escape

  @Test
  func escape_attempt_is_rejected_by_HomeScopeGuard() throws {
    let home = try TempHome()
    // Build a fake `.local` directory structure where `.local` itself is a
    // symlink pointing outside $HOME. HomeScopeGuard walks the ancestor chain
    // and rejects any link whose real target escapes.
    let outside = FileManager.default.temporaryDirectory.appending(
      component: "tc-installer-outside-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }

    let dotLocal = home.root.appending(component: ".local", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: dotLocal, withDestinationURL: outside)

    let paths = home.paths(
      overridingLocalBin: dotLocal.appending(component: "bin", directoryHint: .isDirectory)
    )
    let client = makeClient(paths: paths)

    let install = client.install()
    if case .failure(.destinationOutsideHome) = install {
      // expected
    } else {
      Issue.record("Expected .destinationOutsideHome, got \(install)")
    }

    let probe = client.probe()
    if case .failed(.destinationOutsideHome, _) = probe {
      // expected — probe must flag the escape too.
    } else {
      Issue.record("Expected probe to return .failed(.destinationOutsideHome), got \(probe)")
    }
  }
}
