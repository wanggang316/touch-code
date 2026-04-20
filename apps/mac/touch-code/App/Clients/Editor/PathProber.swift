import Foundation

/// `$PATH` lookup seam. The live implementation walks each colon-separated entry of `PATH`
/// and returns the first readable/executable match. Tests inject a fake for hermetic runs.
nonisolated protocol PathProber: Sendable {
  /// Resolves a bare binary name (no `/`) to an absolute `URL`, or `nil` if not found.
  /// If `binaryName` contains `/`, the prober treats it as an absolute path and returns a
  /// URL only when the file exists and is executable.
  func locate(binaryName: String) -> URL?
}

/// Live prober. Reads `PATH` from the captured environment snapshot; uses
/// `FileManager.default` at call sites (never stored, to keep the struct `Sendable`).
/// Caching belongs one layer up in `EditorService` (the plan's refresh triggers live there).
nonisolated struct LivePathProber: PathProber {
  let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func locate(binaryName: String) -> URL? {
    let fileManager = FileManager.default
    if binaryName.contains("/") {
      let url = URL(fileURLWithPath: binaryName)
      return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }
    guard let path = environment["PATH"] else { return nil }
    for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
      let candidate = URL(fileURLWithPath: String(directory))
        .appendingPathComponent(binaryName, isDirectory: false)
      if fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }
}

/// Test double. Takes a dictionary of `binaryName → URL` (or multiple URLs per name to test
/// PATH-ordering) and returns the recorded value.
nonisolated struct FakePathProber: PathProber {
  let resolution: [String: URL?]

  func locate(binaryName: String) -> URL? {
    resolution[binaryName] ?? nil
  }
}
