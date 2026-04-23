import Foundation

/// Abstraction over environment-variable lookup. `LiveEnvironment` reads
/// `ProcessInfo.processInfo.environment`; tests inject a fake to control `$PATH` without
/// touching the real shell.
nonisolated protocol EnvironmentVariableProvider: Sendable {
  func value(for key: String) -> String?
}

nonisolated struct LiveEnvironment: EnvironmentVariableProvider {
  func value(for key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
  }
}

/// Resolves the absolute path of the `gh` CLI once per app session and caches the result.
///
/// Concurrent callers share a single resolution via a single-flight `Task`: the first
/// `resolve()` starts the probe, subsequent callers `await` the in-flight task. Subsequent
/// calls after resolution return the cached `URL?` without any filesystem activity.
///
/// `invalidate()` clears the cache so the next `resolve()` re-probes — used by the Settings
/// panel's "Re-check" button.
///
/// The prober is injected at init time so tests can assert single-flight behaviour by
/// counting invocations. The production path uses `Self.livePathProbe()` which iterates
/// `$PATH` components and checks each for an executable `gh` file.
actor GhExecutableResolver {
  static let shared = GhExecutableResolver()

  typealias Prober = @Sendable () async -> URL?

  private enum CacheState {
    case empty
    case resolving(Task<URL?, Never>)
    case resolved(URL?)
  }

  private let prober: Prober
  private var cache: CacheState = .empty

  init(prober: @escaping Prober = GhExecutableResolver.livePathProbe()) {
    self.prober = prober
  }

  /// Returns the cached `gh` path, resolving on first call. Concurrent callers share the
  /// resolution task so the prober runs at most once per cache generation.
  func resolve() async -> URL? {
    switch cache {
    case .resolved(let url):
      return url
    case .resolving(let task):
      return await task.value
    case .empty:
      let prober = self.prober
      let task = Task<URL?, Never> { await prober() }
      cache = .resolving(task)
      let result = await task.value
      // Re-check cache: if `invalidate()` fired while the probe ran, don't clobber the
      // subsequent .empty state with a stale .resolved value.
      if case .resolving = cache {
        cache = .resolved(result)
      }
      return result
    }
  }

  /// Clears the cache so the next `resolve()` re-probes. No-op when already empty.
  func invalidate() {
    cache = .empty
  }

  /// Live prober: iterates `$PATH` components and returns the first directory that contains
  /// an executable `gh` file. `PATH` unset or empty → `nil` (i.e., "gh not installed").
  ///
  /// `FileManager` is constructed inside the closure rather than captured, because
  /// `FileManager` is not `Sendable` in Swift 6 strict-concurrency mode.
  static func livePathProbe(
    env: any EnvironmentVariableProvider = LiveEnvironment()
  ) -> Prober {
    return {
      guard let pathValue = env.value(for: "PATH"), !pathValue.isEmpty else { return nil }
      let fileManager = FileManager.default
      for component in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = URL(fileURLWithPath: String(component))
          .appendingPathComponent("gh")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir),
          !isDir.boolValue
        else { continue }
        if fileManager.isExecutableFile(atPath: candidate.path) {
          return candidate
        }
      }
      return nil
    }
  }
}
