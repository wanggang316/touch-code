import ComposableArchitecture
import Foundation
import TouchCodeCore

@Reducer
struct SpaceManagerFeature {
  @ObservableState
  struct State: Equatable {
    var renameDraft: RenameDraft?
    var pendingRemoval: PendingSpaceRemoval?
  }

  struct RenameDraft: Equatable {
    var spaceID: SpaceID
    var text: String
  }

  struct PendingSpaceRemoval: Equatable {
    var spaceID: SpaceID
    var displayName: String
    var projectCount: Int
    var worktreeCount: Int
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)

    case renameRowTapped(SpaceID, currentName: String)
    case renameDraftChanged(String)
    case renameCommitted
    case renameCancelled

    case removeTapped(SpaceID, name: String)
    case removeConfirmed
    case removeCancelled

    case reordered(IndexSet, Int)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .renameRowTapped(let spaceID, let currentName):
        state.renameDraft = RenameDraft(spaceID: spaceID, text: currentName)
        return .none

      case .renameDraftChanged(let newText):
        state.renameDraft?.text = newText
        return .none

      case .renameCommitted:
        guard let draft = state.renameDraft else { return .none }
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        try? hierarchyClient.renameSpace(draft.spaceID, trimmed)
        state.renameDraft = nil
        return .none

      case .renameCancelled:
        state.renameDraft = nil
        return .none

      case .removeTapped(let spaceID, let name):
        let snapshot = hierarchyClient.snapshot()
        guard let space = snapshot.spaces.first(where: { $0.id == spaceID }) else {
          return .none
        }
        let projectCount = space.projects.count
        let worktreeCount = space.projects.reduce(0) { $0 + $1.worktrees.count }
        state.pendingRemoval = PendingSpaceRemoval(
          spaceID: spaceID,
          displayName: name,
          projectCount: projectCount,
          worktreeCount: worktreeCount
        )
        return .none

      case .removeConfirmed:
        guard let pending = state.pendingRemoval else { return .none }
        // Double-gate: re-check that we're not removing the last Space
        let snapshot = hierarchyClient.snapshot()
        guard snapshot.spaces.count > 1 else { return .none }
        try? hierarchyClient.removeSpace(pending.spaceID)
        state.pendingRemoval = nil
        return .none

      case .removeCancelled:
        state.pendingRemoval = nil
        return .none

      case .reordered(let source, let destination):
        hierarchyClient.reorderSpaces(source, destination)
        return .none
      }
    }
  }
}
