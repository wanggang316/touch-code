import ComposableArchitecture
import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Server-side handlers for the `editor.*` IPC surface.
///
/// Binds the three `EditorIPCMethod` endpoints to the App-tier `EditorClient` (which owns the
/// `LiveEditorService` + registry + spawner) and `HierarchyClient` (which resolves Panel →
/// Worktree via the catalog snapshot). Every throw at the handler boundary is translated into
/// an `EditorIPCError` before crossing the wire so the App-tier `EditorError` type never
/// leaves the app.
///
/// Wiring: `AppBootstrap` (C3+C4's plan 0003) registers a `MethodRouter` that dispatches the
/// three method names to the matching method on this class. Until 0003 merges into this
/// branch, `EditorHandlers` is unit-tested in isolation (see `EditorHandlersTests`); the
/// `MethodRouter` registration is a one-line drop-in at merge time.
///
/// Threading: methods are `@MainActor` because they read `HierarchyClient.snapshot()`
/// (which is `@MainActor @Sendable`). The underlying `editorClient.open` spawns off the
/// main actor; that's the actor's decision, not ours.
@MainActor
final class EditorHandlers {
  private let editor: EditorClient
  private let hierarchy: HierarchyClient

  init(editor: EditorClient, hierarchy: HierarchyClient) {
    self.editor = editor
    self.hierarchy = hierarchy
  }

  // MARK: - editor.describe

  /// Returns the current editor registry with installation status. Purely read-only —
  /// no hierarchy lookup needed.
  func describe() async -> EditorDescribeResponse {
    let descriptors = await editor.describe()
    return EditorDescribeResponse(descriptors: descriptors.map { $0.toDTO() })
  }

  // MARK: - editor.open

  /// Resolves the target Worktree, then spawns the requested editor against its directory.
  ///
  /// Worktree resolution order:
  ///   1. `request.worktreeID` — explicit UUID wins; must point to a live Worktree in the
  ///      current catalog snapshot.
  ///   2. `request.panelID` — walks `Space/Project/Worktree/Tab/Panel` in the snapshot until
  ///      the matching Panel is found; its parent Worktree wins.
  ///   3. Neither present, or neither resolves → `EditorIPCError.unresolvedWorktree`.
  ///
  /// The `preferred` editor id is forwarded verbatim to `EditorClient.open`, which owns the
  /// 4-tier fallback chain (explicit → per-Project override → global default → Finder). The
  /// resolved Project is passed through so per-Project overrides apply.
  func open(_ request: EditorOpenRequest) async throws -> EditorOpenResponse {
    guard let (project, worktree) = resolveWorktree(
      worktreeID: request.worktreeID,
      panelID: request.panelID
    ) else {
      throw EditorIPCError.unresolvedWorktree
    }

    let directory = URL(fileURLWithPath: worktree.path, isDirectory: true)
    do {
      let choice = try await editor.open(directory, request.preferred, project.id)
      return EditorOpenResponse(choice: choice.toDTO(), worktreePath: worktree.path)
    } catch let error as EditorError {
      throw Self.mapToIPCError(error)
    }
  }

  // MARK: - editor.setDefault

  /// Updates the per-Project `defaultEditor` override. Looks up the Project's parent Space in
  /// the current snapshot (the wire contract only carries `projectID`; the app-side topology
  /// requires both IDs to mutate).
  func setDefault(_ request: EditorSetDefaultRequest) throws -> EditorSetDefaultResponse {
    let projectID = ProjectID(raw: request.projectID)
    let snapshot = hierarchy.snapshot()
    guard let space = snapshot.spaces.first(where: { space in
      space.projects.contains(where: { $0.id == projectID })
    }) else {
      throw EditorIPCError.unknownProject
    }
    try hierarchy.setDefaultEditor(projectID, space.id, request.editorID)
    return EditorSetDefaultResponse()
  }

  // MARK: - private helpers

  /// Resolves `(Project, Worktree)` in the current snapshot using either explicit `worktreeID`
  /// or a `panelID` → parent-Worktree walk. Returns `nil` if neither path resolves.
  private func resolveWorktree(
    worktreeID: UUID?,
    panelID: UUID?
  ) -> (Project, Worktree)? {
    let snapshot = hierarchy.snapshot()
    if let worktreeID {
      let id = WorktreeID(raw: worktreeID)
      for space in snapshot.spaces {
        for project in space.projects {
          if let worktree = project.worktrees.first(where: { $0.id == id }) {
            return (project, worktree)
          }
        }
      }
      return nil
    }
    if let panelID {
      let id = PanelID(raw: panelID)
      for space in snapshot.spaces {
        for project in space.projects {
          for worktree in project.worktrees where worktree.tabs.contains(where: { $0.panels.contains(where: { $0.id == id }) }) {
            return (project, worktree)
          }
        }
      }
      return nil
    }
    return nil
  }

  /// App-tier `EditorError` → wire-tier `EditorIPCError`. Stable mapping — do NOT renumber
  /// `EditorIPCError`'s rawValues; the CLI compares against them.
  static func mapToIPCError(_ error: EditorError) -> EditorIPCError {
    switch error {
    case .unresolvedWorktree:    return .unresolvedWorktree
    case .notInstalled:          return .notInstalled
    case .spawnFailed:           return .spawnFailed
    case .nonZeroExit:           return .nonZeroExit
    case .timedOut:              return .timedOut
    case .badTemplate:           return .badTemplate
    case .notADirectory:         return .notADirectory
    }
  }
}
