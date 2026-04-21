import Foundation

/// Result of executing one of the `tc skill …` subcommands. Runners write to `stdout`
/// and `stderr` and return an `exitCode`; the `main.swift` dispatcher flushes them and
/// calls `exit(code)`. Tests inspect the strings directly.
public struct RunnerOutcome: Sendable, Equatable {
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String

  public init(exitCode: Int32, stdout: String, stderr: String) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

// MARK: - Install

public struct InstallRunner {
  public struct Inputs: Sendable {
    public let agent: AgentID
    public let dest: URL?
    public let link: Bool
    public let force: Bool
    public let dryRun: Bool
    public let emitJSON: Bool

    public init(
      agent: AgentID,
      dest: URL? = nil,
      link: Bool = false,
      force: Bool = false,
      dryRun: Bool = false,
      emitJSON: Bool = false
    ) {
      self.agent = agent
      self.dest = dest
      self.link = link
      self.force = force
      self.dryRun = dryRun
      self.emitJSON = emitJSON
    }
  }

  public let installer: SkillInstaller
  public let config: AgentsConfig
  public let spawner: ProcessSpawner
  public let enforceHomeScope: Bool
  /// Cache directory pi clones mirrors into. Overridden by tests; production
  /// installs always use `~/.pi/agent/git` via `PiMirror.defaultCacheRoot`.
  public let piCacheRoot: URL

  public init(
    installer: SkillInstaller,
    config: AgentsConfig,
    spawner: ProcessSpawner = RealProcessSpawner(),
    enforceHomeScope: Bool = true,
    piCacheRoot: URL = PiMirror.defaultCacheRoot
  ) {
    self.installer = installer
    self.config = config
    self.spawner = spawner
    self.enforceHomeScope = enforceHomeScope
    self.piCacheRoot = piCacheRoot
  }

  public func run(_ inputs: Inputs) -> RunnerOutcome {
    guard let agentConfig = config.config(for: inputs.agent) else {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "Unknown agent '\(inputs.agent.rawValue)' in agents.json\n"
      )
    }
    switch agentConfig.installMode {
    case .copy:      return runCopy(inputs: inputs)
    case .piInstall: return runPiInstall(inputs: inputs, agentConfig: agentConfig)
    }
  }

  // MARK: - Copy-mode install

  private func runCopy(inputs: Inputs) -> RunnerOutcome {
    if inputs.link && inputs.dryRun {
      // Both are acceptable individually; combining them is allowed and exercised in tests.
    }
    guard let destination = resolveDestination(for: inputs) else {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "Agent '\(inputs.agent.rawValue)' has no defaultPath for \(TargetOS.current.rawValue).\n"
      )
    }
    // CLI-layer HOME-scope check (defence in depth; installer also enforces — DEC-4).
    // `HomeScopeGuard` walks the ancestor chain with `lstat` semantics so a crafted
    // symlink in an intermediate directory cannot slip past a literal prefix check.
    if enforceHomeScope, !HomeScopeGuard.isInsideHome(destination, fileSystem: installer.fileSystem) {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "Refusing to install outside $HOME: \(destination.path)\n"
      )
    }

    let mode: InstallMode = inputs.link ? .symlink : .copy
    let options = InstallOptions(
      force: inputs.force,
      dryRun: inputs.dryRun,
      enforceHomeScope: enforceHomeScope
    )

    do {
      let result = try installer.install(to: destination, mode: mode, options: options)
      return emitInstallSuccess(inputs: inputs, result: result, mode: mode)
    } catch let error as InstallError {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "\(error.errorDescription ?? "install failed")\n"
      )
    } catch {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "install failed: \(error)\n"
      )
    }
  }

  private func resolveDestination(for inputs: Inputs) -> URL? {
    if let dest = inputs.dest { return dest }
    guard let path = config.defaultPath(for: inputs.agent) else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func emitInstallSuccess(
    inputs: Inputs,
    result: InstallResult,
    mode: InstallMode
  ) -> RunnerOutcome {
    if inputs.emitJSON {
      let payload = InstallStatusJSON(
        schemaVersion: 1,
        agent: inputs.agent.rawValue,
        destination: result.destination.path,
        bundleVersion: result.marker.version,
        installMode: mode.rawValue,
        result: result.kind.rawValue,
        filesWritten: result.filesWritten.count
      )
      let text = encodeJSON(payload)
      return RunnerOutcome(exitCode: 0, stdout: text + "\n", stderr: "")
    }
    var lines: [String] = []
    switch result.kind {
    case .noop:
      lines.append("touch-code \(result.marker.version): already up to date at \(result.destination.path)")
    case .installed:
      lines.append("touch-code \(result.marker.version): installed at \(result.destination.path)")
    case .reinstalled:
      lines.append("touch-code \(result.marker.version): reinstalled at \(result.destination.path)")
    case .dryRun:
      lines.append("touch-code \(result.marker.version): would install at \(result.destination.path)")
      for url in result.filesWritten {
        lines.append("  + \(url.path)")
      }
    }
    return RunnerOutcome(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
  }

  // MARK: - pi-install

  // Follow-up: split pi-install body into smaller helpers (input validation,
  // cache-path resolution, process spawn). For T1, suppressing the lint below to unblock.
  // swiftlint:disable:next function_body_length
  private func runPiInstall(inputs: Inputs, agentConfig: AgentConfig) -> RunnerOutcome {
    if inputs.dest != nil {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "--dest is not supported with --pi (pi manages its own cache path)\n"
      )
    }
    if inputs.link {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "--link is not supported with --pi\n"
      )
    }
    guard let mirrorURL = agentConfig.mirrorURL else {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "agents.json is missing mirrorURL for 'pi'\n"
      )
    }

    let piPath: String
    do {
      guard let located = try spawner.locateBinary(named: "pi") else {
        return RunnerOutcome(
          exitCode: 2,
          stdout: "",
          stderr: "pi binary not on PATH — install from https://github.com/mariozechner/pi then retry.\n"
        )
      }
      piPath = located
    } catch {
      return RunnerOutcome(
        exitCode: 2,
        stdout: "",
        stderr: "failed to locate pi binary: \(error)\n"
      )
    }

    let arg = "git:\(mirrorURL)"
    if inputs.dryRun {
      let text = inputs.emitJSON
        ? encodeJSON(InstallStatusJSON(
            schemaVersion: 1,
            agent: inputs.agent.rawValue,
            destination: nil,
            bundleVersion: (try? installer.readBundledVersion()) ?? "",
            installMode: "pi-install",
            result: "dryRun",
            filesWritten: 0)) + "\n"
        : "touch-code: would run `\(piPath) install \(arg)`\n"
      return RunnerOutcome(exitCode: 0, stdout: text, stderr: "")
    }

    let outcome: ProcessOutcome
    do {
      outcome = try spawner.run(
        executable: piPath,
        arguments: ["install", arg],
        environment: nil
      )
    } catch {
      return RunnerOutcome(
        exitCode: 2,
        stdout: "",
        stderr: "pi spawn failed: \(error)\n"
      )
    }

    let version = (try? installer.readBundledVersion()) ?? ""
    // Verify the mirror pi cloned actually ships the VERSION we bundled. A
    // compromised mirror, cache poisoning, or DNS spoof can trick pi into
    // installing arbitrary content while pi itself exits 0 — without this
    // check, the CLI would declare success anyway. Only run when pi itself
    // succeeded; a pi failure is reported on its own merits.
    let mismatch: String? = outcome.exitCode == 0
      ? verifyPiVersion(mirrorURL: mirrorURL, bundleVersion: version)
      : nil
    let effectiveExit: Int32 = mismatch != nil ? 2 : outcome.exitCode
    let effectiveResult: String = {
      if mismatch != nil { return "versionMismatch" }
      return outcome.exitCode == 0 ? "installed" : "failed"
    }()

    if inputs.emitJSON {
      let payload = InstallStatusJSON(
        schemaVersion: 1,
        agent: inputs.agent.rawValue,
        destination: nil,
        bundleVersion: version,
        installMode: "pi-install",
        result: effectiveResult,
        filesWritten: 0
      )
      return RunnerOutcome(
        exitCode: effectiveExit,
        stdout: encodeJSON(payload) + "\n",
        stderr: outcome.stderr + (mismatch ?? "")
      )
    }
    // Forward pi's own stdout (progress, summary) and trailing-append our success or
    // failure line. On failure we also route the banner to stderr so CI pipelines pick
    // it up in the error stream.
    let piStdout = outcome.stdout
    if let mismatch {
      return RunnerOutcome(
        exitCode: effectiveExit,
        stdout: piStdout,
        stderr: outcome.stderr + mismatch
      )
    }
    if outcome.exitCode == 0 {
      let banner = "touch-code: installed via pi (mirror \(mirrorURL))\n"
      return RunnerOutcome(
        exitCode: 0,
        stdout: piStdout + banner,
        stderr: outcome.stderr
      )
    }
    let banner = "pi install failed (exit \(outcome.exitCode))\n"
    return RunnerOutcome(
      exitCode: outcome.exitCode,
      stdout: piStdout,
      stderr: outcome.stderr + banner
    )
  }

  /// Returns `nil` if pi's cache VERSION matches the bundled VERSION; otherwise a
  /// ready-to-emit error line naming both versions. Missing or unreadable VERSION
  /// at the cache path is treated as a mismatch — we refuse to trust an install
  /// we cannot audit.
  private func verifyPiVersion(mirrorURL: String, bundleVersion: String) -> String? {
    let mirror = PiMirror(rawURL: mirrorURL)
    let versionFile = mirror.cacheDirectory(root: piCacheRoot)
      .appendingPathComponent("VERSION")
    let actual: String
    if let data = installer.fileSystem.contents(atPath: versionFile.path),
       let text = String(bytes: data, encoding: .utf8) {
      actual = text.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      actual = ""
    }
    if actual == bundleVersion { return nil }
    let reported = actual.isEmpty ? "<missing>" : actual
    return "pi install completed but mirror VERSION (\(reported)) "
      + "does not match bundled VERSION (\(bundleVersion)); refusing to trust this install.\n"
  }
}

// MARK: - Uninstall

public struct UninstallRunner {
  public let installer: SkillInstaller
  public let config: AgentsConfig

  public init(installer: SkillInstaller, config: AgentsConfig) {
    self.installer = installer
    self.config = config
  }

  public func run(agent: AgentID) -> RunnerOutcome {
    guard let agentConfig = config.config(for: agent) else {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "Unknown agent '\(agent.rawValue)' in agents.json\n"
      )
    }
    switch agentConfig.installMode {
    case .copy:
      guard let path = config.defaultPath(for: agent) else {
        return RunnerOutcome(exitCode: 1, stdout: "", stderr: "no defaultPath\n")
      }
      let url = URL(fileURLWithPath: path)
      do {
        try installer.uninstall(at: url)
        return RunnerOutcome(
          exitCode: 0,
          stdout: "touch-code: uninstalled from \(url.path)\n",
          stderr: ""
        )
      } catch {
        return RunnerOutcome(
          exitCode: 1,
          stdout: "",
          stderr: "uninstall failed: \(error)\n"
        )
      }
    case .piInstall:
      return RunnerOutcome(
        exitCode: 0,
        stdout: "pi-managed: run `pi remove touch-code-skill` or delete "
          + "~/.pi/agent/git/github.com/wanggang316/touch-code-skill manually.\n",
        stderr: ""
      )
    }
  }
}

// MARK: - Status

public struct StatusRunner {
  public struct Row: Sendable, Equatable {
    public let agent: String
    public let installed: String?
    public let installMode: String?
    public let path: String?
    public let managedByPi: Bool
  }

  public let installer: SkillInstaller
  public let config: AgentsConfig
  public let fileSystem: SkillFileSystem
  /// Pi's mirror-cache root (`~/.pi/agent/git` in production). Tests inject a
  /// temp directory. Matches the convention used by `InstallRunner.piCacheRoot`.
  public let piCacheRoot: URL

  public init(
    installer: SkillInstaller,
    config: AgentsConfig,
    fileSystem: SkillFileSystem = RealSkillFileSystem(),
    piCacheRoot: URL = PiMirror.defaultCacheRoot
  ) {
    self.installer = installer
    self.config = config
    self.fileSystem = fileSystem
    self.piCacheRoot = piCacheRoot
  }

  public func run(emitJSON: Bool) -> RunnerOutcome {
    let bundleVersion = (try? installer.readBundledVersion()) ?? "unknown"
    let rows = collectRows()

    if emitJSON {
      let payload = StatusJSON(
        schemaVersion: 1,
        bundleVersion: bundleVersion,
        rows: rows.map { row in
          StatusJSON.Row(
            agent: row.agent,
            installed: row.installed,
            installMode: row.installMode,
            path: row.path,
            managedByPi: row.managedByPi
          )
        }
      )
      return RunnerOutcome(exitCode: 0, stdout: encodeJSON(payload) + "\n", stderr: "")
    }
    return RunnerOutcome(exitCode: 0, stdout: renderTable(bundleVersion: bundleVersion, rows: rows), stderr: "")
  }

  private func collectRows() -> [Row] {
    AgentID.allCases.map { agent in
      if let agentConfig = config.config(for: agent), agentConfig.installMode == .piInstall {
        return piRow(agent: agent)
      }
      guard let path = config.defaultPath(for: agent) else {
        return Row(agent: agent.rawValue, installed: nil, installMode: nil, path: nil, managedByPi: false)
      }
      let url = URL(fileURLWithPath: path)
      if let marker = try? installer.readMarker(at: url) {
        return Row(
          agent: agent.rawValue,
          installed: marker.version,
          installMode: marker.publicInstallMode,
          path: url.path,
          managedByPi: false
        )
      }
      return Row(
        agent: agent.rawValue,
        installed: nil,
        installMode: nil,
        path: fileSystem.fileExists(atPath: url.path) ? url.path : nil,
        managedByPi: false
      )
    }
  }

  private func piRow(agent: AgentID) -> Row {
    let mirrorURL = config.mirrorURL(for: agent) ?? ""
    let piPath = PiMirror(rawURL: mirrorURL).cacheDirectory(root: piCacheRoot)
    let versionFile = piPath.appendingPathComponent("VERSION")
    let packageFile = piPath.appendingPathComponent("package.json")
    let pathString = fileSystem.fileExists(atPath: piPath.path) ? piPath.path : nil

    if let data = fileSystem.contents(atPath: versionFile.path),
       let text = String(bytes: data, encoding: .utf8) {
      return Row(
        agent: agent.rawValue,
        installed: text.trimmingCharacters(in: .whitespacesAndNewlines),
        installMode: "pi-install",
        path: pathString,
        managedByPi: true
      )
    }
    if let data = fileSystem.contents(atPath: packageFile.path),
       let version = readVersionFromPackageJSON(data) {
      return Row(
        agent: agent.rawValue,
        installed: version,
        installMode: "pi-install",
        path: pathString,
        managedByPi: true
      )
    }
    return Row(
      agent: agent.rawValue,
      installed: nil,
      installMode: nil,
      path: pathString,
      managedByPi: true
    )
  }

  private func readVersionFromPackageJSON(_ data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return obj["version"] as? String
  }

  private func renderTable(bundleVersion: String, rows: [Row]) -> String {
    let header = pad("Agent", 13)
      + " " + pad("Installed", 14)
      + " " + pad("Bundled", 10)
      + " " + pad("Mode", 12)
      + " " + "Path"
    var lines = [header]
    for row in rows {
      let installedCol = row.installed.map { $0 + (row.managedByPi ? " (pi)" : "") } ?? "-"
      let modeCol = row.installMode ?? "-"
      let pathCol = row.path ?? "-"
      lines.append(
        pad(row.agent, 13)
          + " " + pad(installedCol, 14)
          + " " + pad(bundleVersion, 10)
          + " " + pad(modeCol, 12)
          + " " + pathCol
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Width-aware padding using Swift's display-column model. Avoids the byte-count
  /// mis-alignment that `%-Ns` introduces for multibyte names.
  private func pad(_ text: String, _ width: Int) -> String {
    if text.count >= width { return text }
    return text.padding(toLength: width, withPad: " ", startingAt: 0)
  }
}

// MARK: - BundlePath

public struct BundlePathRunner {
  public init() {}

  public func run() -> RunnerOutcome {
    do {
      let url = try SkillBundleLocator.locateSkillBundle()
      return RunnerOutcome(exitCode: 0, stdout: url.path + "\n", stderr: "")
    } catch {
      return RunnerOutcome(
        exitCode: 1,
        stdout: "",
        stderr: "bundle not found: \(error)\n"
      )
    }
  }
}

// MARK: - JSON schemas

/// Public `tc skill install --json` schema. Key names match `agents.json` (DEC-12):
/// `installMode`, not the marker's private `source`.
struct InstallStatusJSON: Codable {
  let schemaVersion: Int
  let agent: String
  let destination: String?
  let bundleVersion: String
  let installMode: String
  let result: String
  let filesWritten: Int
}

/// Public `tc skill status --json` schema.
struct StatusJSON: Codable {
  let schemaVersion: Int
  let bundleVersion: String
  let rows: [Row]

  struct Row: Codable {
    let agent: String
    let installed: String?
    let installMode: String?
    let path: String?
    let managedByPi: Bool
  }
}

private func encodeJSON<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  guard let data = try? encoder.encode(value),
        let text = String(bytes: data, encoding: .utf8) else {
    return "{}"
  }
  return text
}
