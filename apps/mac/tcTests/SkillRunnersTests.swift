import Foundation
import Testing

@testable import tcKit

struct SkillRunnersTests {
  // MARK: - InstallRunner: copy path

  @Test
  func installRunnerCopyWritesTreeAndEmitsHumanOutput() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(),
      enforceHomeScope: false
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .claudeCode, dest: dest))
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("installed at"))
    #expect(outcome.stderr.isEmpty)
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path))
  }

  @Test
  func installRunnerJSONFlagEmitsStructuredPayload() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(),
      enforceHomeScope: false
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .claudeCode, dest: dest, emitJSON: true))
    #expect(outcome.exitCode == 0)
    guard let data = outcome.stdout.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      Issue.record("install JSON was not parseable")
      return
    }
    #expect(obj["schemaVersion"] as? Int == 1)
    #expect(obj["agent"] as? String == "claude-code")
    #expect(obj["installMode"] as? String == "copy")
    #expect(obj["bundleVersion"] as? String == "0.1.0")
    #expect(obj["result"] as? String == "installed")
    // Marker's internal `source` name must not leak into the public JSON.
    #expect(obj["source"] == nil)
  }

  @Test
  func installRunnerDryRunWritesNothing() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(),
      enforceHomeScope: false
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .claudeCode, dest: dest, dryRun: true))
    #expect(outcome.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: dest.path))
    #expect(outcome.stdout.contains("would install"))
  }

  @Test
  func installRunnerRefusesDestinationOutsideHomeWhenScoped() throws {
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(),
      enforceHomeScope: true
    )
    let dest = URL(fileURLWithPath: "/tmp/tc-runner-outside-home-\(UUID().uuidString)")
    let outcome = runner.run(InstallRunner.Inputs(agent: .claudeCode, dest: dest))
    #expect(outcome.exitCode == 1)
    #expect(outcome.stderr.contains("Refusing to install outside"))
    #expect(!FileManager.default.fileExists(atPath: dest.path))
  }

  // MARK: - InstallRunner: pi-install path

  @Test
  func piInstallExitsCode2WhenPiBinaryMissing() throws {
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(whichResult: nil),
      enforceHomeScope: false
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi))
    #expect(outcome.exitCode == 2)
    #expect(outcome.stderr.contains("pi binary not on PATH"))
  }

  @Test
  func piInstallForwardsPiStdoutAlongsideSuccessBanner() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let piCacheRoot = Self.provisionPiCache(version: "0.1.0", under: fixture)
    let spawner = NoopSpawner(
      whichResult: "/usr/local/bin/pi",
      runOutcome: ProcessOutcome(
        exitCode: 0,
        stdout: "Cloning into cache...\nResolving deps...\n",
        stderr: ""
      )
    )
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: spawner,
      enforceHomeScope: false,
      piCacheRoot: piCacheRoot
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi))
    #expect(outcome.exitCode == 0)
    // pi's stdout must be visible to the caller, not swallowed.
    #expect(outcome.stdout.contains("Cloning into cache"))
    #expect(outcome.stdout.contains("Resolving deps"))
    #expect(outcome.stdout.contains("installed via pi"))
  }

  @Test
  func piInstallForwardsPiExitCodeAndCapturesInvocation() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let piCacheRoot = Self.provisionPiCache(version: "0.1.0", under: fixture)
    let spawner = NoopSpawner(whichResult: "/usr/local/bin/pi", runOutcome: ProcessOutcome(exitCode: 0, stdout: "", stderr: ""))
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: spawner,
      enforceHomeScope: false,
      piCacheRoot: piCacheRoot
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi))
    #expect(outcome.exitCode == 0)
    #expect(spawner.recordedCalls.count == 1)
    let call = spawner.recordedCalls.first!
    #expect(call.executable == "/usr/local/bin/pi")
    #expect(call.arguments == ["install", "git:github.com/wanggang316/touch-code-skill"])
  }

  @Test
  func piInstallRejectsMismatchedMirrorVersion() throws {
    // Attacker scenario: pi reports success but the mirror it cloned ships a
    // VERSION that does not match the bundled VERSION. The runner must refuse
    // to declare success and surface both versions in stderr.
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let piCacheRoot = Self.provisionPiCache(version: "9.9.9", under: fixture)
    let spawner = NoopSpawner(
      whichResult: "/usr/local/bin/pi",
      runOutcome: ProcessOutcome(exitCode: 0, stdout: "Installing...\n", stderr: "")
    )
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: spawner,
      enforceHomeScope: false,
      piCacheRoot: piCacheRoot
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi))
    #expect(outcome.exitCode == 2)
    #expect(outcome.stderr.contains("mirror VERSION (9.9.9)"))
    #expect(outcome.stderr.contains("bundled VERSION (0.1.0)"))
    // pi's own stdout is preserved so a human can audit what pi actually did.
    #expect(outcome.stdout.contains("Installing"))
  }

  @Test
  func piInstallRejectsMissingMirrorVersionFile() throws {
    // An empty cache directory means pi claimed to install but no VERSION file
    // landed — possibly a partial clone or a wrong-repo mirror. Refuse to trust.
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let piCacheRoot = fixture.appendingPathComponent("pi-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: piCacheRoot, withIntermediateDirectories: true)
    let spawner = NoopSpawner(
      whichResult: "/usr/local/bin/pi",
      runOutcome: ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
    )
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: spawner,
      enforceHomeScope: false,
      piCacheRoot: piCacheRoot
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi))
    #expect(outcome.exitCode == 2)
    #expect(outcome.stderr.contains("<missing>"))
    #expect(outcome.stderr.contains("0.1.0"))
  }

  @Test
  func piInstallJSONFlagsMismatchInStructuredPayload() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let piCacheRoot = Self.provisionPiCache(version: "1.2.3", under: fixture)
    let spawner = NoopSpawner(
      whichResult: "/usr/local/bin/pi",
      runOutcome: ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
    )
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: spawner,
      enforceHomeScope: false,
      piCacheRoot: piCacheRoot
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi, emitJSON: true))
    #expect(outcome.exitCode == 2)
    guard let data = outcome.stdout.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      Issue.record("pi install JSON unparseable")
      return
    }
    #expect(obj["result"] as? String == "versionMismatch")
  }

  @Test
  func piInstallRejectsDestFlag() throws {
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(whichResult: "/usr/local/bin/pi"),
      enforceHomeScope: false
    )
    let outcome = runner.run(
      InstallRunner.Inputs(agent: .pi, dest: URL(fileURLWithPath: "/tmp/ignored"))
    )
    #expect(outcome.exitCode == 1)
    #expect(outcome.stderr.contains("--dest is not supported with --pi"))
  }

  @Test
  func piInstallRejectsLinkFlag() throws {
    let runner = InstallRunner(
      installer: Self.installer(),
      config: Self.config(),
      spawner: NoopSpawner(whichResult: "/usr/local/bin/pi"),
      enforceHomeScope: false
    )
    let outcome = runner.run(InstallRunner.Inputs(agent: .pi, link: true))
    #expect(outcome.exitCode == 1)
    #expect(outcome.stderr.contains("--link is not supported with --pi"))
  }

  // MARK: - UninstallRunner

  @Test
  func uninstallRunnerRemovesCopyModeAgent() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("touch-code")

    // Install first, then uninstall. Uninstall currently uses defaultPath, so we need a
    // custom AgentsConfig that points at the fixture.
    let customConfig = Self.config(
      claudeCodeDefaultPath: dest.path,
      codexDefaultPath: fixture.appendingPathComponent("codex").path
    )
    let installer = Self.installer()
    _ = try installer.install(
      to: dest, mode: .copy,
      options: InstallOptions(enforceHomeScope: false)
    )
    #expect(FileManager.default.fileExists(atPath: dest.path))

    let runner = UninstallRunner(installer: installer, config: customConfig)
    let outcome = runner.run(agent: .claudeCode)
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("uninstalled"))
    #expect(!FileManager.default.fileExists(atPath: dest.path))
  }

  @Test
  func uninstallRunnerPiEmitsGuidanceNotFileOps() throws {
    let runner = UninstallRunner(installer: Self.installer(), config: Self.config())
    let outcome = runner.run(agent: .pi)
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("pi-managed"))
    #expect(outcome.stdout.contains("pi remove"))
  }

  // MARK: - StatusRunner

  @Test
  func statusRunnerReportsAllDashWhenNothingInstalled() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let config = Self.config(
      claudeCodeDefaultPath: fixture.appendingPathComponent("none-claude").path,
      codexDefaultPath: fixture.appendingPathComponent("none-codex").path
    )
    let runner = StatusRunner(
      installer: Self.installer(),
      config: config,
      piCacheRoot: fixture.appendingPathComponent("no-such-pi")
    )
    let outcome = runner.run(emitJSON: false)
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("claude-code"))
    #expect(outcome.stdout.contains("codex"))
    #expect(outcome.stdout.contains("pi"))
  }

  @Test
  func statusRunnerDetectsInstalledClaudeCode() throws {
    let fixture = Self.tempDir()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let dest = fixture.appendingPathComponent("claude-install")
    let installer = Self.installer()
    _ = try installer.install(
      to: dest, mode: .copy,
      options: InstallOptions(enforceHomeScope: false)
    )
    let config = Self.config(
      claudeCodeDefaultPath: dest.path,
      codexDefaultPath: fixture.appendingPathComponent("never").path
    )
    let runner = StatusRunner(
      installer: installer,
      config: config,
      piCacheRoot: fixture.appendingPathComponent("no-such-pi")
    )
    let outcome = runner.run(emitJSON: true)
    guard let data = outcome.stdout.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = obj["rows"] as? [[String: Any]] else {
      Issue.record("status JSON unparseable")
      return
    }
    #expect(obj["schemaVersion"] as? Int == 1)
    let claude = rows.first { ($0["agent"] as? String) == "claude-code" }
    #expect(claude?["installed"] as? String == "0.1.0")
    #expect(claude?["installMode"] as? String == "copy")
    #expect(claude?["path"] as? String == dest.path)
  }

  // MARK: - BundlePathRunner

  @Test
  func bundlePathRunnerPrintsLocatedBundle() throws {
    // Override via env var so the runner finds the in-repo fixture regardless of
    // DerivedData layout.
    let override = Self.repoSkillBundle().path
    setenv(SkillBundleLocator.EnvKey.skillBundle, override, 1)
    defer { unsetenv(SkillBundleLocator.EnvKey.skillBundle) }
    let outcome = BundlePathRunner().run()
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == override)
  }

  // MARK: - Helpers

  static func installer() -> SkillInstaller {
    SkillInstaller(bundleURL: repoSkillBundle())
  }

  static func repoSkillBundle() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // tcTests
      .deletingLastPathComponent() // mac
      .deletingLastPathComponent() // apps
      .deletingLastPathComponent() // repo root
      .appendingPathComponent("skills/touch-code-cli")
  }

  static func config(
    claudeCodeDefaultPath: String? = nil,
    codexDefaultPath: String? = nil
  ) -> AgentsConfig {
    AgentsConfig(
      version: 1,
      agents: [
        "claude-code": AgentConfig(
          defaultPath: [
            "darwin": claudeCodeDefaultPath ?? "~/.claude/skills/touch-code",
            "linux": claudeCodeDefaultPath ?? "~/.claude/skills/touch-code",
          ],
          mirrorURL: nil,
          installMode: .copy
        ),
        "codex": AgentConfig(
          defaultPath: [
            "darwin": codexDefaultPath ?? "~/.codex/skills/touch-code",
            "linux": codexDefaultPath ?? "~/.codex/skills/touch-code",
          ],
          mirrorURL: nil,
          installMode: .copy
        ),
        "pi": AgentConfig(
          defaultPath: nil,
          mirrorURL: "github.com/wanggang316/touch-code-skill",
          installMode: .piInstall
        ),
      ]
    )
  }

  static func tempDir() -> URL {
    let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".touch-code-runners-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  /// Lays out a pi-style cache (`<root>/<slug>/VERSION`) so
  /// `InstallRunner.verifyPiVersion` has something to read. The slug matches
  /// the mirror URL in `Self.config()`.
  static func provisionPiCache(version: String, under fixture: URL) -> URL {
    let root = fixture.appendingPathComponent("pi-cache", isDirectory: true)
    let cloneDir = root.appendingPathComponent(
      "github.com/wanggang316/touch-code-skill",
      isDirectory: true
    )
    try? FileManager.default.createDirectory(at: cloneDir, withIntermediateDirectories: true)
    try? Data("\(version)\n".utf8).write(
      to: cloneDir.appendingPathComponent("VERSION")
    )
    return root
  }
}

/// Minimal `ProcessSpawner` stub for runner tests. Records every `run` invocation and
/// returns `runOutcome` (default: exit 0, empty streams). `whichResult` controls the
/// return value of `locateBinary`.
///
/// `@unchecked Sendable` without a lock is deliberate: Swift Testing drives each test
/// sequentially on a single task; the recorded-calls array is never touched concurrently.
/// If parallel execution is enabled in the future, add a lock back here.
final class NoopSpawner: ProcessSpawner, @unchecked Sendable {
  struct Call: Equatable {
    let executable: String
    let arguments: [String]
  }
  private let whichResult: String?
  private let runOutcome: ProcessOutcome
  private(set) var recordedCalls: [Call] = []

  init(
    whichResult: String? = "/usr/local/bin/pi",
    runOutcome: ProcessOutcome = ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
  ) {
    self.whichResult = whichResult
    self.runOutcome = runOutcome
  }

  func locateBinary(named name: String) throws -> String? {
    whichResult
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> ProcessOutcome {
    recordedCalls.append(Call(executable: executable, arguments: arguments))
    return runOutcome
  }
}
