import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer backing the "Archived Worktrees" sheet opened from the
/// Project `⋯` menu. The view reads archived worktrees live from
/// `HierarchyManager.catalog` on each render; this reducer owns only
/// transient UX state (the in-sheet error banner + a pending
/// force-remove payload awaiting confirmation).
@Reducer
struct ArchivedWorktreesFeature {
  @ObservableState
  struct State: Equatable {
    let projectID: ProjectID
    let spaceID: SpaceID
    var banner: String?
    /// Payload for the force-remove confirmation dialog. Non-nil →
    /// dialog visible.
    var pendingForceRemove: PendingForceRemove?
  }

  struct PendingForceRemove: Equatable {
    var worktreeID: WorktreeID
    var worktreeName: String
    var uncommittedFiles: [String]
  }

  enum Action: Equatable {
    case unarchiveTapped(WorktreeID)
    case removeTapped(WorktreeID, displayName: String)
    case removeFinished(worktreeID: WorktreeID, error: String?)
    case removeRequiresForce(
      worktreeID: WorktreeID,
      displayName: String,
      uncommittedFiles: [String]
    )
    case forceRemoveConfirmed
    case forceRemoveCancelled
    case dismissBanner
    case closeButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case let .unarchiveTapped(worktreeID):
        do {
          try hierarchyClient.setWorktreeArchived(worktreeID, false)
          state.banner = nil
        } catch {
          state.banner = "Failed to unarchive: \(error.localizedDescription)"
        }
        return .none

      case let .removeTapped(worktreeID, displayName):
        let projectID = state.projectID
        let spaceID = state.spaceID
        let client = hierarchyClient
        return .run { send in
          do {
            try await client.removeWorktreeWithGit(worktreeID, projectID, spaceID, false)
            await send(.removeFinished(worktreeID: worktreeID, error: nil))
          } catch let gitError as GitWorktreeError {
            if case .uncommittedChanges(let files) = gitError {
              await send(.removeRequiresForce(
                worktreeID: worktreeID,
                displayName: displayName,
                uncommittedFiles: files
              ))
              return
            }
            await send(.removeFinished(worktreeID: worktreeID, error: humanReadable(gitError)))
          } catch {
            await send(.removeFinished(worktreeID: worktreeID, error: error.localizedDescription))
          }
        }

      case let .removeFinished(_, error):
        state.pendingForceRemove = nil
        state.banner = error
        return .none

      case let .removeRequiresForce(worktreeID, displayName, files):
        state.pendingForceRemove = PendingForceRemove(
          worktreeID: worktreeID,
          worktreeName: displayName,
          uncommittedFiles: files
        )
        state.banner = nil
        return .none

      case .forceRemoveConfirmed:
        guard let pending = state.pendingForceRemove else { return .none }
        let projectID = state.projectID
        let spaceID = state.spaceID
        let client = hierarchyClient
        let worktreeID = pending.worktreeID
        state.pendingForceRemove = nil
        return .run { send in
          do {
            try await client.removeWorktreeWithGit(worktreeID, projectID, spaceID, true)
            await send(.removeFinished(worktreeID: worktreeID, error: nil))
          } catch let gitError as GitWorktreeError {
            await send(.removeFinished(worktreeID: worktreeID, error: humanReadable(gitError)))
          } catch {
            await send(.removeFinished(worktreeID: worktreeID, error: error.localizedDescription))
          }
        }

      case .forceRemoveCancelled:
        state.pendingForceRemove = nil
        return .none

      case .dismissBanner:
        state.banner = nil
        return .none

      case .closeButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }

  private func humanReadable(_ error: GitWorktreeError) -> String {
    switch error {
    case .executableMissing: return "The bundled wt helper is missing."
    case .branchExists(let name): return "Branch \"\(name)\" already exists."
    case .invalidBranchName(let name): return "Invalid branch name: \(name)"
    case .refNotFound(let ref): return "Ref not found: \(ref)"
    case .fetchFailed(let detail): return "fetch failed: \(detail)"
    case .uncommittedChanges: return "The worktree has uncommitted changes."
    case .worktreeLocked(let detail): return "Worktree is locked: \(detail)"
    case .commandFailed(_, let stderr): return stderr
    }
  }
}
