import Foundation
import Testing
import tcKit

@testable import touch_code

/// Covers install / uninstall / probe state transitions, the script composer,
/// and the privileged-shell invocation contract. Probe uses a real filesystem
/// rooted at a fresh tmp directory; install / uninstall use
/// `RecordingPrivilegedShell` so no real `osascript` is invoked.
@MainActor
@Suite("CLIInstallerClient")
struct CLIInstallerClientTests {
  // MARK: - Fixture helpers

  private final class TempHome {
    let root: URL
    let installDir: URL
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
      let installDir = root.appending(component: "usr/local/bin", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
      self.root = root
      self.installDir = installDir
      self.bundledTc = binary
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }

    func paths() -> CLIInstallerClient.Paths {
      let legacyDir = root.appending(component: ".local/bin", directoryHint: .isDirectory)
      return CLIInstallerClient.Paths(
        tcSymlink: installDir.appending(component: "tc", directoryHint: .notDirectory),
        tcodeSymlink: installDir.appending(component: "tcode", directoryHint: .notDirectory),
        legacyLocalBinTc: legacyDir.appending(component: "tc", directoryHint: .notDirectory),
        legacyLocalBinTcode: legacyDir.appending(component: "tcode", directoryHint: .notDirectory),
        bundledTcBinary: bundledTc
      )
    }
  }

  private func makeClient(
    paths: CLIInstallerClient.Paths,
    fileSystem: CLIFilesystem = RealCLIFilesystem(),
    privilegedShell: RecordingPrivilegedShell = RecordingPrivilegedShell()
  ) -> (CLIInstallerClient, RecordingPrivilegedShell) {
    let client = CLIInstallerClient(paths: paths, fileSystem: fileSystem, privilegedShell: privilegedShell)
    return (client, privilegedShell)
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
    let (client, _) = makeClient(paths: home.paths())

    #expect(client.probe() == .notInstalled)
  }

  @Test
  func probe_onlyTcPresent_returnsNotInstalled() throws {
    // Partial state: tc is our symlink, tcode absent. Probe collapses to
    // .notInstalled so a subsequent install() completes the pair.
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    let (client, _) = makeClient(paths: paths)

    #expect(client.probe() == .notInstalled)
  }

  @Test
  func probe_bothOurs_returnsInstalled() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    try FileManager.default.createSymbolicLink(at: paths.tcodeSymlink, withDestinationURL: home.bundledTc)
    let (client, _) = makeClient(paths: paths)

    assertInstalled(client.probe())
  }

  @Test
  func probe_tcOursButTcodeForeign_returnsCollision() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcodeSymlink)
    let (client, _) = makeClient(paths: paths)

    if case .collision(let owner) = client.probe() {
      #expect(owner == paths.tcodeSymlink)
    } else {
      Issue.record("Expected .collision, got \(client.probe())")
    }
  }

  // MARK: - Install

  @Test
  func install_freshMachine_callsPrivilegedShellOnceWithComposedScript() throws {
    let home = try TempHome()
    let paths = home.paths()
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    switch result {
    case .success(let status): assertInstalled(status)
    case .failure(let error): Issue.record("Install failed: \(error)")
    }
    #expect(shell.calls.count == 1)
    let script = shell.calls.first?.command ?? ""
    #expect(script.contains("set -e"))
    #expect(script.contains("mkdir -p /usr/local/bin"))
    #expect(script.contains("ln -s '\(home.bundledTc.path)' '\(paths.tcSymlink.path)'"))
    #expect(script.contains("ln -s '\(home.bundledTc.path)' '\(paths.tcodeSymlink.path)'"))
    #expect(shell.calls.first?.prompt.contains("administrator access") == true)
  }

  @Test
  func install_whenAlreadyInstalled_skipsPrivilegedDialog() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    try FileManager.default.createSymbolicLink(at: paths.tcodeSymlink, withDestinationURL: home.bundledTc)
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    switch result {
    case .success(let status): assertInstalled(status)
    case .failure(let error): Issue.record("Install failed: \(error)")
    }
    #expect(shell.calls.isEmpty)
  }

  @Test
  func install_whenForeign_returnsDestinationExistsNotOurs_andSkipsDialog() throws {
    let home = try TempHome()
    let paths = home.paths()
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    if case .failure(.destinationExistsNotOurs(let url)) = result {
      #expect(url == paths.tcSymlink)
    } else {
      Issue.record("Expected .destinationExistsNotOurs, got \(result)")
    }
    #expect(shell.calls.isEmpty)
  }

  @Test
  func install_userCancels_returnsUserCancelled() throws {
    let home = try TempHome()
    let shell = RecordingPrivilegedShell()
    shell.result = .throwError(.userCancelled)
    let (client, _) = makeClient(paths: home.paths(), privilegedShell: shell)

    let result = client.install()

    if case .failure(.userCancelled) = result {
      // expected
    } else {
      Issue.record("Expected .userCancelled, got \(result)")
    }
  }

  @Test
  func install_scriptFailure_returnsScriptFailedWithStderr() throws {
    let home = try TempHome()
    let shell = RecordingPrivilegedShell()
    shell.result = .throwError(.scriptFailed(stderr: "ln: permission denied"))
    let (client, _) = makeClient(paths: home.paths(), privilegedShell: shell)

    let result = client.install()

    if case .failure(.scriptFailed(let stderr)) = result {
      #expect(stderr == "ln: permission denied")
    } else {
      Issue.record("Expected .scriptFailed, got \(result)")
    }
  }

  @Test
  func install_bundleMissing_returnsBundleMissing() throws {
    let home = try TempHome()
    var paths = home.paths()
    paths.bundledTcBinary = nil
    let (client, shell) = makeClient(paths: paths)

    let result = client.install()

    if case .failure(.bundleMissing) = result {
      // expected
    } else {
      Issue.record("Expected .bundleMissing, got \(result)")
    }
    #expect(shell.calls.isEmpty)
  }

  // MARK: - Uninstall

  @Test
  func uninstall_whenInstalledByUs_callsPrivilegedShellOnceWithRmScript() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    try FileManager.default.createSymbolicLink(at: paths.tcodeSymlink, withDestinationURL: home.bundledTc)
    let (client, shell) = makeClient(paths: paths)

    let result = client.uninstall()

    #expect(result == .success(.notInstalled))
    #expect(shell.calls.count == 1)
    let script = shell.calls.first?.command ?? ""
    #expect(script.contains("set -e"))
    #expect(script.contains("rm '\(paths.tcSymlink.path)'"))
    #expect(script.contains("rm '\(paths.tcodeSymlink.path)'"))
  }

  @Test
  func uninstall_whenNothingPresent_skipsPrivilegedDialog() throws {
    let home = try TempHome()
    let (client, shell) = makeClient(paths: home.paths())

    let result = client.uninstall()

    #expect(result == .success(.notInstalled))
    #expect(shell.calls.isEmpty)
  }

  @Test
  func uninstall_whenForeignPresent_reportsCollisionAndSkipsDialog() throws {
    let home = try TempHome()
    let paths = home.paths()
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcSymlink)
    let (client, shell) = makeClient(paths: paths)

    let result = client.uninstall()

    if case .success(.collision(let owner)) = result {
      #expect(owner == paths.tcSymlink)
    } else {
      Issue.record("Expected collision, got \(result)")
    }
    #expect(shell.calls.isEmpty)
  }

  @Test
  func uninstall_whenTcodeIsForeign_refusesAndKeepsTc() throws {
    let home = try TempHome()
    let paths = home.paths()
    try FileManager.default.createSymbolicLink(at: paths.tcSymlink, withDestinationURL: home.bundledTc)
    try Data("#!/bin/sh\necho foreign\n".utf8).write(to: paths.tcodeSymlink)
    let (client, shell) = makeClient(paths: paths)

    let result = client.uninstall()

    if case .success(.collision(let owner)) = result {
      #expect(owner == paths.tcodeSymlink)
    } else {
      Issue.record("Expected collision on tcode, got \(result)")
    }
    #expect(shell.calls.isEmpty)
    // tc symlink still in place — uninstall did not touch it.
    #expect(FileManager.default.fileExists(atPath: paths.tcSymlink.path))
  }

  // MARK: - Script composers (pure-function unit tests)

  @Test
  func composeInstallScript_freshMachine_includesMkdirAndBothLnLines() {
    let bundled = URL(fileURLWithPath: "/Applications/TouchCode.app/Contents/Resources/bin/tc")
    let tc = URL(fileURLWithPath: "/usr/local/bin/tc")
    let tcode = URL(fileURLWithPath: "/usr/local/bin/tcode")

    let script = CLIInstallerClient.composeInstallScript(bundled: bundled, absentPaths: [tc, tcode])

    #expect(script == """
      set -e
      mkdir -p /usr/local/bin
      ln -s '/Applications/TouchCode.app/Contents/Resources/bin/tc' '/usr/local/bin/tc'
      ln -s '/Applications/TouchCode.app/Contents/Resources/bin/tc' '/usr/local/bin/tcode'
      """)
  }

  @Test
  func composeUninstallScript_bothOurs_emitsRmLines() {
    let tc = URL(fileURLWithPath: "/usr/local/bin/tc")
    let tcode = URL(fileURLWithPath: "/usr/local/bin/tcode")

    let script = CLIInstallerClient.composeUninstallScript(paths: [tc, tcode])

    #expect(script == """
      set -e
      rm '/usr/local/bin/tc'
      rm '/usr/local/bin/tcode'
      """)
  }
}
