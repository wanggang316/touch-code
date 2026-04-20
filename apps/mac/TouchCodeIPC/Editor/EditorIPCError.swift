import Foundation

/// Wire-safe error code table for the `editor.*` IPC surface.
///
/// Maps 1:1 to the App-tier `EditorError` enum. `EditorHandlers` translates at the handler
/// boundary so the app-tier type never crosses the socket — callers only see a
/// `{ code, message }` JSON-RPC error envelope with numeric codes from this table.
///
/// Numeric codes are stable wire contract; do NOT renumber. Gaps left for future additions.
public nonisolated enum EditorIPCError: Int, Error, Equatable, Sendable {
  /// Neither `worktreeID` nor a `panelID` that resolves to a Worktree was supplied.
  case unresolvedWorktree = 100

  /// The editor binary was not found on `$PATH` (bare-name template) or at the absolute
  /// path (absolute template).
  case notInstalled = 101

  /// Child process exited non-zero within the 5 s budget.
  case nonZeroExit = 102

  /// Child process was still alive at the 5 s deadline.
  case timedOut = 103

  /// `Process.run()` threw — permissions, quarantine, or kernel-level denial.
  case spawnFailed = 104

  /// Custom-editor template failed validation.
  case badTemplate = 105

  /// The directory passed to `open` does not exist or is a file, not a directory.
  case notADirectory = 106
}

public extension EditorIPCError {
  /// Human-readable short description used in the JSON-RPC error envelope's `message` slot.
  /// Callers in `tc` CLI can log this verbatim; in-app toasts should use
  /// `EditorFeature.editorErrorDescription` which surfaces more context.
  var shortMessage: String {
    switch self {
    case .unresolvedWorktree:
      return "No worktree resolved (pass <worktree> or run from inside a touch-code Panel)."
    case .notInstalled:
      return "Editor not installed."
    case .nonZeroExit:
      return "Editor exited with a non-zero status."
    case .timedOut:
      return "Editor did not exit within the 5 s budget."
    case .spawnFailed:
      return "Failed to spawn editor process."
    case .badTemplate:
      return "Editor template failed validation."
    case .notADirectory:
      return "Path is not a directory."
    }
  }
}
