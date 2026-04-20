import Foundation
import TouchCodeCore

/// External-editor dispatch surface. Consumed directly by the Worktree-header dropdown (M6)
/// and by the `editor.*` IPC handlers (M7b). All methods are `async` — resolution may probe
/// PATH; `open` always spawns a child process.
public nonisolated protocol EditorService: Sendable {
  /// Snapshot of the registry: built-ins + user-defined, each marked installed or missing.
  func describe() async -> [EditorDescriptor]

  /// Resolves the effective editor for a given `(preferred, projectID)` pair, without
  /// opening anything. Used by the dropdown to label its default selection.
  func resolve(
    preferred: EditorID?,
    projectID: ProjectID?
  ) async -> EditorDescriptor

  /// Opens `directory` in the resolved editor. Throws `EditorError` on any failure along the
  /// resolution → spawn → wait pipeline. No silent fallthrough: if the preferred editor is
  /// not installed, surfaces `.notInstalled` rather than falling to the next tier.
  @discardableResult
  func open(
    directory: URL,
    preferred: EditorID?,
    projectID: ProjectID?
  ) async throws -> EditorChoice
}
