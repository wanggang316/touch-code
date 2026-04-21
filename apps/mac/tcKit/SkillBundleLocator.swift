import Foundation

/// Resolves the path to the bundled `touch-code-skill/` directory and the shipped
/// `agents.json` resource. The app bundle's `Contents/Resources/` is the primary source;
/// an env-var override and a repo-root fallback cover dev iteration. Pure path resolution
/// — never reads file contents.
public enum SkillBundleLocator {
  public enum LocatorError: Error, Equatable {
    /// `touch-code-skill/` could not be found via any resolution phase.
    case bundleNotFound
    /// `apps/mac/Resources/agents.json` could not be located during a dev-run walk.
    case agentsJSONNotFound
  }

  /// Environment-variable overrides for dev iteration. Production .app invocations don't
  /// set these; when set, they win over all other resolution phases so contributors can
  /// point `tc` at in-repo fixtures without rebuilding the .app.
  public enum EnvKey {
    public static let skillBundle = "TOUCH_CODE_SKILL_BUNDLE"
    public static let agentsJSON = "TOUCH_CODE_AGENTS_JSON"
  }

  /// Resolution phases are tried in order:
  /// 0. `$TOUCH_CODE_SKILL_BUNDLE` env var — dev override.
  /// 1. `Bundle.main.resourceURL?/touch-code-skill` — normal `.app` invocation where
  ///    `Bundle.main` is the app bundle (`tc` launched via `NSWorkspace`) OR `tc`
  ///    launched directly from `touch-code.app/Contents/MacOS/tc` (in which case
  ///    `Bundle.main.resourceURL` is `Contents/MacOS/`, so we also probe phase 2).
  /// 2. `<executable>/../Resources/touch-code-skill` — sibling of the Mach-O path. This
  ///    covers the direct-binary-from-bundle case.
  /// 3. Repo walk from `<executable>` looking for `touch-code-skill/` — dev run.
  public static func locateSkillBundle(
    executableURL: URL? = Bundle.main.executableURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    if let override = environment[EnvKey.skillBundle], !override.isEmpty {
      let expanded = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
      if isDirectory(expanded, fileSystem: FileManager.default) {
        return expanded
      }
    }
    if let url = Bundle.main.resourceURL?
      .appendingPathComponent("touch-code-cli", isDirectory: true),
      isDirectory(url, fileSystem: FileManager.default) {
      return url
    }
    guard let executable = executableURL else { throw LocatorError.bundleNotFound }

    let sibling = executable
      .deletingLastPathComponent()            // Contents/MacOS
      .deletingLastPathComponent()            // Contents
      .appendingPathComponent("Resources/touch-code-cli", isDirectory: true)
    if isDirectory(sibling, fileSystem: FileManager.default) {
      return sibling
    }

    if let repoPeer = repoWalk(from: executable, matching: "skills/touch-code-cli") {
      return repoPeer
    }
    throw LocatorError.bundleNotFound
  }

  /// Same three-phase resolution as `locateSkillBundle`, but resolves `agents.json`.
  public static func locateAgentsJSON(
    executableURL: URL? = Bundle.main.executableURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> URL {
    if let override = environment[EnvKey.agentsJSON], !override.isEmpty {
      let expanded = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: expanded.path) {
        return expanded
      }
    }
    if let url = Bundle.main.url(forResource: "agents", withExtension: "json") {
      return url
    }
    guard let executable = executableURL else { throw LocatorError.agentsJSONNotFound }

    let sibling = executable
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/agents.json")
    if FileManager.default.fileExists(atPath: sibling.path) {
      return sibling
    }

    if let repoResource = repoWalk(from: executable, matching: "apps/mac/Resources/agents.json") {
      return repoResource
    }
    throw LocatorError.agentsJSONNotFound
  }

  // MARK: - Helpers

  private static func isDirectory(_ url: URL, fileSystem fm: FileManager) -> Bool {
    var isDir: ObjCBool = false
    return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  /// Walk upward from `url`'s directory up to 12 levels, checking whether
  /// `<ancestor>/<needle>` exists. Returns the first matching URL or nil.
  private static func repoWalk(from url: URL, matching needle: String) -> URL? {
    let fm = FileManager.default
    var directory = url.deletingLastPathComponent()
    for _ in 0..<12 {
      let candidate = directory.appendingPathComponent(needle)
      if fm.fileExists(atPath: candidate.path) {
        return candidate
      }
      let parent = directory.deletingLastPathComponent()
      if parent == directory { break }
      directory = parent
    }
    return nil
  }
}
