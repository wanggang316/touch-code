import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Lightweight sheet reducers for the four structural creation flows.
/// Each feature holds a draft name (+ per-sheet extras), validates on
/// submit, dispatches the matching `HierarchyClient` command, and
/// dismisses. More complex flows (`AddProject` folder picker + git-root
/// auto-detect, `NewWorktree` path templating + git CLI invocation) are
/// minimal-viable here; M6 review will flag what to promote into the
/// detailed UX for production dogfooding.

@Reducer
struct NewSpaceFeature {
  @ObservableState
  struct State: Equatable {
    var draftName: String = ""
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case submitButtonTapped
    case cancelButtonTapped
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .submitButtonTapped:
        let name = state.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        _ = hierarchyClient.createSpace(name)
        return .run { _ in await dismiss() }
      case .cancelButtonTapped:
        return .run { _ in await dismiss() }
      }
    }
  }
}

@Reducer
struct NewTabFeature {
  @ObservableState
  struct State: Equatable {
    let spaceID: SpaceID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    var draftName: String = ""
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case submitButtonTapped
    case cancelButtonTapped
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .submitButtonTapped:
        let trimmed = state.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = trimmed.isEmpty ? nil : trimmed
        _ = try? hierarchyClient.createTab(state.worktreeID, state.projectID, state.spaceID, name)
        return .run { _ in await dismiss() }
      case .cancelButtonTapped:
        return .run { _ in await dismiss() }
      }
    }
  }
}
