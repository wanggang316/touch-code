import Foundation
import TouchCodeCore

/// Live `EditorService`. Dependency-injected: pass any `ProcessSpawner` and `PathProber` for
/// tests; defaults construct a `FoundationProcessSpawner` + `LivePathProber` at call time.
///
/// Read closures are `@Sendable` captures with optional returns so that a collected
/// `SettingsStore` or `HierarchyManager` (future weak-captured in the live factory) yields
/// `nil` and the fallback chain progresses to the next tier without crashing.
nonisolated struct LiveEditorService: EditorService {
  let spawner: any ProcessSpawner
  let prober: any PathProber
  let globalDefault: @Sendable () -> EditorID?
  let customEditors: @Sendable () -> [CustomEditor]
  let projectOverride: @Sendable (ProjectID) -> EditorID?

  init(
    spawner: any ProcessSpawner = FoundationProcessSpawner(),
    prober: any PathProber = LivePathProber(),
    globalDefault: @escaping @Sendable () -> EditorID? = { nil },
    customEditors: @escaping @Sendable () -> [CustomEditor] = { [] },
    projectOverride: @escaping @Sendable (ProjectID) -> EditorID? = { _ in nil }
  ) {
    self.spawner = spawner
    self.prober = prober
    self.globalDefault = globalDefault
    self.customEditors = customEditors
    self.projectOverride = projectOverride
  }

  // Protocol declares these `async` so future resolvers can do disk I/O; the current live
  // implementation is synchronous. Swift allows a sync method to satisfy an async
  // requirement — callers still write `await service.describe()`.
  func describe() -> [EditorDescriptor] {
    (try? EditorRegistry.merged(with: customEditors(), prober: prober)) ?? []
  }

  func resolve(
    preferred: EditorID?,
    projectID: ProjectID?
  ) -> EditorDescriptor {
    let registry = (try? EditorRegistry.merged(with: customEditors(), prober: prober)) ?? []
    return resolve(registry: registry, preferred: preferred, projectID: projectID)
  }

  @discardableResult
  func open(
    directory: URL,
    preferred: EditorID?,
    projectID: ProjectID?
  ) async throws -> EditorChoice {
    try ensureDirectoryExists(directory)
    let registry = try EditorRegistry.merged(with: customEditors(), prober: prober)
    let descriptor = resolve(registry: registry, preferred: preferred, projectID: projectID)

    guard case .installed(let binaryURL) = descriptor.installation else {
      throw EditorError.notInstalled(id: descriptor.id, binary: descriptor.template.binary)
    }

    let argv = buildArgv(binaryURL: binaryURL, template: descriptor.template, directory: directory)
    let choice = EditorChoice(
      id: descriptor.id,
      displayName: descriptor.displayName,
      binaryPath: binaryURL,
      argv: argv
    )
    let env = EditorEnv.build()
    let outcome = await spawner.spawnForOpen(
      argv: argv,
      env: env,
      cwd: directory,
      timeout: SpawnContract.timeout
    )
    switch outcome {
    case .exited(let code, _) where code == 0:
      return choice
    case .exited(let code, let stderr):
      throw EditorError.nonZeroExit(code: code, stderr: stderr)
    case .timedOut:
      throw EditorError.timedOut
    case .spawnFailed(let reason):
      throw EditorError.spawnFailed(reason: reason)
    }
  }

  // MARK: - Resolution

  /// Four-tier fallback: explicit preferred → per-project override → global default → finder.
  /// **No silent fallthrough.** An unresolved preferred/override/global editor returns a
  /// `.missingBinary` descriptor; `open` surfaces `.notInstalled` from it. Only when all
  /// three upstream tiers are `nil` does this method consult Finder.
  func resolve(
    registry: [EditorDescriptor],
    preferred: EditorID?,
    projectID: ProjectID?
  ) -> EditorDescriptor {
    if let id = preferred, let match = registry.first(where: { $0.id == id }) {
      return match
    }
    if let projectID, let id = projectOverride(projectID), let match = registry.first(where: { $0.id == id }) {
      return match
    }
    if let id = globalDefault(), let match = registry.first(where: { $0.id == id }) {
      return match
    }
    // Prefer an *installed* Finder so the dropdown never labels a broken editor as the
    // resolved default. `/usr/bin/open` is expected to always exist on macOS; the installed-
    // only fallback is defensive against a file-system anomaly (or a FakePathProber in
    // tests) where it doesn't. See 0005 plan DEC-16.
    if let finder = registry.first(where: { $0.id == "finder" && $0.isInstalled }) {
      return finder
    }
    // Finder is in the registry but not installed → fall back to the missingBinary
    // descriptor. `open()` will throw `.notInstalled(id: "finder", binary: "open")`, which
    // the UI surfaces as a clear error rather than a silent wrong-editor launch.
    if let finder = registry.first(where: { $0.id == "finder" }) { return finder }
    // Registry somehow lacks a Finder entry (never happens with the hard-coded allowlist;
    // guard covers a future registry-refactor regression). Synthesise the placeholder.
    return EditorDescriptor(
      id: "finder",
      displayName: "Finder",
      origin: .builtin,
      template: CommandTemplate(binary: "open", args: ["{dir}"]),
      installation: .missingBinary(expected: "open")
    )
  }

  // MARK: - argv construction

  /// `{dir}` is substituted literally into exactly one argv slot. Everything else passes
  /// through verbatim — no shell, no quoting, no expansion.
  func buildArgv(binaryURL: URL, template: CommandTemplate, directory: URL) -> [String] {
    let substituted = template.args.map { arg -> String in
      arg == CommandTemplate.dirPlaceholder ? directory.path : arg
    }
    return [binaryURL.path] + substituted
  }

  private func ensureDirectoryExists(_ url: URL) throws {
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
      throw EditorError.notADirectory(path: url.path)
    }
  }
}
