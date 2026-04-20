import ArgumentParser
import Foundation

/// `tc skill` top-level. Subcommands dispatch to the runners in SkillRunners.swift.
public struct SkillCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "skill",
    abstract: "Install, inspect, and remove the touch-code agent skill.",
    subcommands: [
      Install.self,
      Uninstall.self,
      Status.self,
      BundlePath.self,
    ]
  )

  public init() {}
}

extension SkillCommand {
  public struct Install: ParsableCommand {
    public static let configuration = CommandConfiguration(
      commandName: "install",
      abstract: "Install the touch-code skill into an agent's skill directory."
    )

    @Flag(help: "Target agent (exactly one).")
    public var agent: AgentID

    @Option(help: "Override the default install path (copy-mode agents only).")
    public var dest: String?

    @Flag(name: .customLong("link"), help: "Symlink instead of copy (contributors).")
    public var link: Bool = false

    @Flag(name: .customLong("force"), help: "Overwrite existing files without prompting.")
    public var force: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Print what would happen; change nothing.")
    public var dryRun: Bool = false

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    public var emitJSON: Bool = false

    public init() {}

    public func run() throws {
      let runner = try Self.buildRunner()
      let outcome = runner.run(
        InstallRunner.Inputs(
          agent: agent,
          dest: dest.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
          link: link,
          force: force,
          dryRun: dryRun,
          emitJSON: emitJSON
        )
      )
      FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
      FileHandle.standardError.write(Data(outcome.stderr.utf8))
      if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }

    static func buildRunner() throws -> InstallRunner {
      let bundleURL = try SkillBundleLocator.locateSkillBundle()
      let installer = SkillInstaller(bundleURL: bundleURL)
      let config = try AgentsConfig.loadFromMainBundle()
      return InstallRunner(installer: installer, config: config)
    }
  }

  public struct Uninstall: ParsableCommand {
    public static let configuration = CommandConfiguration(
      commandName: "uninstall",
      abstract: "Remove the touch-code skill from an agent's skill directory."
    )

    @Flag(help: "Target agent (exactly one).")
    public var agent: AgentID

    public init() {}

    public func run() throws {
      let bundleURL = try SkillBundleLocator.locateSkillBundle()
      let installer = SkillInstaller(bundleURL: bundleURL)
      let config = try AgentsConfig.loadFromMainBundle()
      let runner = UninstallRunner(installer: installer, config: config)
      let outcome = runner.run(agent: agent)
      FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
      FileHandle.standardError.write(Data(outcome.stderr.utf8))
      if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }
  }

  public struct Status: ParsableCommand {
    public static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Show which agents have the touch-code skill installed."
    )

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    public var emitJSON: Bool = false

    public init() {}

    public func run() throws {
      let bundleURL = try SkillBundleLocator.locateSkillBundle()
      let installer = SkillInstaller(bundleURL: bundleURL)
      let config = try AgentsConfig.loadFromMainBundle()
      let runner = StatusRunner(installer: installer, config: config)
      let outcome = runner.run(emitJSON: emitJSON)
      FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
      FileHandle.standardError.write(Data(outcome.stderr.utf8))
      if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }
  }

  public struct BundlePath: ParsableCommand {
    public static let configuration = CommandConfiguration(
      commandName: "bundle-path",
      abstract: "Print the absolute path to the bundled touch-code-skill/ directory."
    )

    public init() {}

    public func run() throws {
      let outcome = BundlePathRunner().run()
      FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
      FileHandle.standardError.write(Data(outcome.stderr.utf8))
      if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }
  }
}
