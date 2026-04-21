import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer for the standalone Settings window. Holds sidebar selection + the General pane's
/// `EditorFeature` state. T2/T3/T4 compose their per-pane reducers alongside `general` in a
/// future wave — the window shell stays narrow in T1.
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

    init(selection: SettingsSection? = nil, general: EditorFeature.State = .init()) {
      self.selection = selection
      self.general = general
    }

    /// Section the detail column should render. Falls back to `.general` when nothing is
    /// selected — matches M16 "re-open defaults to General" and prevents an empty-detail
    /// flash on first open.
    var effectiveSection: SettingsSection { selection ?? .general }
  }

  enum Action: Equatable {
    case selectionChanged(SettingsSection?)
    case general(EditorFeature.Action)
    /// Fired by `SettingsWindowView`'s `.onDisappear`. Clears sidebar selection per M16.
    case windowClosed
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
      case .windowClosed:
        state.selection = nil
        return .none
      }
    }
  }
}
