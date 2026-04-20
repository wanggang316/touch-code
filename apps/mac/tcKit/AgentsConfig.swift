import Foundation

/// Identifies an agent that `tc skill install` knows how to target.
///
/// Raw values are the canonical on-disk names used in `agents.json` and in the installed
/// skill directory (e.g. `~/.claude/skills/touch-code/`).
public enum AgentID: String, CaseIterable, Codable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case pi
}

/// Host operating system. `agents.json`'s `defaultPath` dictionary is keyed by this.
public enum TargetOS: String, Sendable {
  case darwin
  case linux

  /// The host OS `tc` is currently running on.
  public static var current: TargetOS {
    #if os(macOS)
    return .darwin
    #else
    return .linux
    #endif
  }
}

/// How `tc skill install` should install a given agent's skill.
///
/// - `.copy`: materialise files at `defaultPath[os]`.
/// - `.piInstall`: shell out to `pi install git:<mirrorURL>`; no filesystem write by `tc`.
public enum AgentInstallMode: String, Codable, Sendable {
  case copy
  case piInstall = "pi-install"
}

/// Per-agent configuration loaded from `agents.json`.
public struct AgentConfig: Codable, Equatable, Sendable {
  public var defaultPath: [String: String]?
  public var mirrorURL: String?
  public var installMode: AgentInstallMode
}

/// Source of truth for per-agent install paths and the pi mirror URL. Shipped read-only in
/// `apps/mac/Resources/agents.json`; bundled into `touch-code.app/Contents/Resources/`.
public struct AgentsConfig: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var agents: [String: AgentConfig]

  public func config(for agent: AgentID) -> AgentConfig? {
    agents[agent.rawValue]
  }

  /// Returns the default install path for `agent` on `os`, with `~` already expanded against
  /// `NSHomeDirectory()`. Returns nil when the agent has no `defaultPath` entry (e.g. pi).
  public func defaultPath(for agent: AgentID, os: TargetOS = .current) -> String? {
    guard let raw = config(for: agent)?.defaultPath?[os.rawValue] else { return nil }
    return (raw as NSString).expandingTildeInPath
  }

  public func mirrorURL(for agent: AgentID) -> String? {
    config(for: agent)?.mirrorURL
  }
}

public enum AgentsConfigError: Error, Equatable {
  /// Decoded `version` field did not match `AgentsConfig.currentVersion`.
  case unknownVersion(Int)
  /// `agents.json` could not be located on disk.
  case resourceNotFound
}

extension AgentsConfig {
  /// Decode `agents.json` from `url` and enforce the version contract.
  public static func load(
    from url: URL,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> AgentsConfig {
    let data = try Data(contentsOf: url)
    let config = try decoder.decode(AgentsConfig.self, from: data)
    guard config.version == AgentsConfig.currentVersion else {
      throw AgentsConfigError.unknownVersion(config.version)
    }
    return config
  }

  /// Load `agents.json` from the app bundle or a repo-relative fallback.
  ///
  /// Provisional implementation for M2 — walks up from `Bundle.main.executableURL` in three
  /// phases: (1) `Bundle.main.url(forResource:)`, (2) `<app>/Contents/Resources/agents.json`
  /// sibling-to-executable lookup, (3) repo-root walk up to locate
  /// `apps/mac/Resources/agents.json` (for `swift run` / direct-binary invocations during
  /// development). M3 replaces steps 2+3 with `SkillBundleLocator.locateAgentsJSON`.
  public static func loadFromMainBundle() throws -> AgentsConfig {
    if let url = Bundle.main.url(forResource: "agents", withExtension: "json") {
      return try load(from: url)
    }
    guard let executable = Bundle.main.executableURL else {
      throw AgentsConfigError.resourceNotFound
    }
    let fm = FileManager.default
    // Phase 2: .app/Contents/MacOS/tc → .app/Contents/Resources/agents.json
    let siblingResources = executable
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/agents.json")
    if fm.fileExists(atPath: siblingResources.path) {
      return try load(from: siblingResources)
    }
    // Phase 3: walk up looking for apps/mac/Resources/agents.json (dev-run, tests).
    var directory = executable.deletingLastPathComponent()
    for _ in 0..<12 {
      let candidate = directory.appendingPathComponent("apps/mac/Resources/agents.json")
      if fm.fileExists(atPath: candidate.path) {
        return try load(from: candidate)
      }
      let parent = directory.deletingLastPathComponent()
      if parent == directory { break } // reached filesystem root
      directory = parent
    }
    throw AgentsConfigError.resourceNotFound
  }
}
