import Foundation

/// Central constants for the spawn contract. Referenced by `EditorService+Live`, the
/// `FoundationProcessSpawner`, and the tests that assert the numbers.
///
/// See 0005 exec plan M5 + C8 design doc §Spawn contract.
nonisolated enum SpawnContract {
  /// Wall-clock budget for the child to exit. Past this, the spawner sends SIGTERM.
  static let timeout: Duration = .seconds(5)

  /// Grace period between SIGTERM and SIGKILL. The allowlist wrappers typically exit on
  /// SIGTERM; SIGKILL guarantees we never leak a stuck child.
  static let sigtermGrace: Duration = .seconds(1)

  /// Maximum stdout / stderr captured per child. Sufficient for surfacing first-line
  /// messages without unbounded memory growth.
  static let maxCapturedBytes = 8 * 1024
}
