import Foundation
import TouchCodeCore

/// Errors surfaced by `EditorService`. Every case maps directly to the design's error table:
/// UI toasts from in-app callers; JSON-RPC error codes from the `editor.*` IPC surface (M7a).
public nonisolated enum EditorError: Error, Equatable, Sendable {
  /// The editor binary was not found on `$PATH` (for bare-name templates) or is missing /
  /// not executable (for absolute-path templates). `id` is the editor choice that failed;
  /// `binary` is the expected binary name / path.
  case notInstalled(id: EditorID, binary: String)

  /// `Process.run()` threw — typically permissions or macOS quarantine.
  case spawnFailed(reason: String)

  /// Child exited non-zero within the 5 s budget.
  case nonZeroExit(code: Int32, stderr: String)

  /// Child was still alive at the 5 s deadline. Spawner sent SIGTERM then SIGKILL.
  case timedOut

  /// Custom template failed validation. `reason` is a short human-readable explanation.
  case badTemplate(id: EditorID, reason: String)

  /// The directory passed to `open` does not exist or is a file.
  case notADirectory(path: String)

  /// `tc open` was invoked with no `<worktree>` and no `TOUCH_CODE_PANEL_ID`. Never raised
  /// from in-app callers (they always resolve a Worktree from the current selection).
  case unresolvedWorktree
}
