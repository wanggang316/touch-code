import Foundation

/// Resolves the path to the bundled `touch-code-skill/` directory and the shipped
/// `agents.json` resource. The app bundle's `Contents/Resources/` is the primary source;
/// the repo root is the dev-run fallback. Pure path resolution — never reads file contents.
public enum SkillBundleLocator {
  public enum LocatorError: Error, Equatable {
    /// `touch-code-skill/` could not be found via any resolution phase.
    case bundleNotFound
    /// `apps/mac/Resources/agents.json` could not be located during a dev-run walk.
    case agentsJSONNotFound
  }

  /// Resolution phases are tried in order:
  /// 1. `Bundle.main.resourceURL?/touch-code-skill` — normal `.app` invocation where
  ///    `Bundle.main` is the app bundle.
  /// 2. `<executable>/../../Resources/touch-code-skill` — `tc` launched directly from
  ///    `touch-code.app/Contents/MacOS/tc` (commandLineTool shares the app bundle).
  /// 3. repo walk from `<executable>` looking for `touch-code-skill/` as a peer of
  ///    `apps/` — dev run from `swift run` or directly-built binary in DerivedData.
  public static func locateSkillBundle(
    executableURL: URL? = Bundle.main.executableURL
  ) throws -> URL {
    let fm = FileManager.default

    if let url = Bundle.main.resourceURL?
      .appendingPathComponent("touch-code-skill", isDirectory: true),
      isDirectory(url, fileSystem: fm) {
      return url
    }
    guard let executable = executableURL else { throw LocatorError.bundleNotFound }

    let siblingResources = executable
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/touch-code-skill", isDirectory: true)
    if isDirectory(siblingResources, fileSystem: fm) {
      return siblingResources
    }

    if let repoPeer = repoWalk(from: executable, matching: "touch-code-skill") {
      return repoPeer
    }
    throw LocatorError.bundleNotFound
  }

  /// Same three-phase resolution as `locateSkillBundle`, but resolves `agents.json` in
  /// `Resources/`. Intended to back `AgentsConfig.loadFromMainBundle`'s M3 implementation.
  public static func locateAgentsJSON(
    executableURL: URL? = Bundle.main.executableURL
  ) throws -> URL {
    let fm = FileManager.default

    if let url = Bundle.main.url(forResource: "agents", withExtension: "json") {
      return url
    }
    guard let executable = executableURL else { throw LocatorError.agentsJSONNotFound }

    let siblingResources = executable
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/agents.json")
    if fm.fileExists(atPath: siblingResources.path) {
      return siblingResources
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
