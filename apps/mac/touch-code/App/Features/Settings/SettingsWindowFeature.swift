import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer for the standalone Settings window. Holds sidebar selection + the General pane's
/// `EditorFeature` state plus a per-`ProjectID` slice of `RepositorySettingsFeature.State`
/// for each Repository pane the user has visited (T4).
///
/// Selection is *not* persisted. Spec M16 requires that closing the window drops the
/// selection and that re-opening defaults to General. `windowClosed` resets `selection` to
/// `nil`; `SettingsWindowView` treats `nil` as "render General".
@Reducer
struct SettingsWindowFeature {
  @ObservableState
  struct State: Equatable {
    var selection: SettingsSection?
    var general: EditorFeature.State = .init()
    var repositoryPanes: IdentifiedArrayOf<RepositorySettingsFeature.State> = []

    init(
      selection: SettingsSection? = nil,
      general: EditorFeature.State = .init(),
      repositoryPanes: IdentifiedArrayOf<RepositorySettingsFeature.State> = []
    ) {
      self.selection = selection
      self.general = general
      self.repositoryPanes = repositoryPanes
    }

    /// Section the detail column should render. Falls back to `.general` when nothing is
    /// selected — matches M16 "re-open defaults to General" and prevents an empty-detail
    /// flash on first open.
    var effectiveSection: SettingsSection { selection ?? .general }
  }

  enum Action: Equatable {
    case selectionChanged(SettingsSection?)
    case general(EditorFeature.Action)
    case repositoryPanes(IdentifiedActionOf<RepositorySettingsFeature>)
    /// Fired by `SettingsWindowView`'s `.onDisappear`. Clears sidebar selection per M16.
    case windowClosed
    /// Fired from the view on every `HierarchyManager.catalog` delta. Reducer prunes a
    /// Repository-scoped selection whose backing Project has disappeared from the catalog —
    /// spec Acceptance Criteria "当主窗口关闭 Project A，则选中自动回落到全局 General".
    case projectsChanged(Set<ProjectID>)
  }

  var body: some Reducer<State, Action> {
    Scope(state: \.general, action: \.general) {
      EditorFeature()
    }
    Reduce { state, action in
      switch action {
      case .selectionChanged(let next):
        state.selection = next
        return .none
      case .general:
        return .none
      case .repositoryPanes:
        return .none
      case .windowClosed:
        state.selection = nil
        return .none
      case .projectsChanged(let currentIDs):
        // Prune repository panes for projects that no longer exist.
        state.repositoryPanes.removeAll { !currentIDs.contains($0.id) }
        // Clear selection if it points to a disappeared project.
        switch state.selection {
        case .repositoryGeneral(let projectID), .repositoryHooks(let projectID):
          if !currentIDs.contains(projectID) {
            state.selection = nil
          }
        default:
          break
        }
        return .none
      }
    }
    .forEach(\.repositoryPanes, action: \.repositoryPanes) {
      RepositorySettingsFeature()
    }
  }
}
