import Foundation

/// Outcome of a single `runWorktreeLifecycleScript` invocation. The
/// caller (HierarchyManager wrappers + the toast presenter) inspects the
/// case to decide between "block / fail-warn / silent skip".
///
/// `stdout` payloads carry combined stdout+stderr because lifecycle
/// scripts surface in a single scrollable monospace view; tests assert
/// on the merged buffer.
enum LifecycleScriptResult: Sendable, Equatable {
  /// The phase's script field was nil-or-empty — no Process was spawned.
  case skipped
  /// Process exited with status 0.
  case success(stdout: String)
  /// Process exited non-zero. `stdout` is the full captured buffer up
  /// to termination.
  case failure(exitCode: Int32, stdout: String)
}
