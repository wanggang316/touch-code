import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Thin host feature for the Settings sheet. M6b ships with one pane — the Editors pane —
/// hosted via a nested `EditorFeature` state. Additional panes (keybindings, theme, telemetry)
/// extend this reducer without churning the sheet-presentation plumbing in `RootFeature`.
@Reducer
struct SettingsSheetFeature {
  @ObservableState
  struct State: Equatable {
    /// The sheet owns its own `EditorFeature` state so in-sheet edits don't conflict with
    /// the root-level `EditorFeature` that drives the Worktree-header dropdown. On dismiss
    /// the root feature re-reads settings, keeping both states in sync via the
    /// `SettingsWriter` single source of truth.
    var editor: EditorFeature.State = .init()
  }

  enum Action: Equatable {
    case editor(EditorFeature.Action)
    case dismissTapped
  }

  var body: some Reducer<State, Action> {
    Scope(state: \.editor, action: \.editor) {
      EditorFeature()
    }
    Reduce { _, action in
      switch action {
      case .editor:
        return .none
      case .dismissTapped:
        // Actual dismiss happens at the root via @Presents. The action is a signalling
        // no-op the view can send when the user clicks Done; the presentation dismiss
        // action from the parent closes the sheet.
        return .none
      }
    }
  }
}
