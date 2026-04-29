import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer backing the Worktree Header row: branch label + Open-in split
/// button + Git Viewer toggle.
///
/// User-facing side effects stay in the reducer so TestStore can prove
/// them. Editor opens are emitted as `.delegate(.openEditor(...))` rather
/// than dispatched through `EditorClient` directly; `RootFeature` forwards
/// them into `EditorFeature.openRequested` (resolving `editorID: nil` via
/// `EditorFeature.resolveDefault` first).
@Reducer
struct WorktreeHeaderFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case onAppear
    case openDefaultEditorTapped(worktreePath: String, projectID: ProjectID?)
    case openEditorTapped(editorID: EditorID, worktreePath: String, projectID: ProjectID?)
    /// Dropdown menu item tapped. Resolves the worktree path and projectID
    /// from the current selection at action-handle time so the open targets
    /// the live selection rather than the path captured when the Menu's
    /// NSMenuItems were first built (SwiftUI bridges Menu content to
    /// NSMenuItem actions that don't always refresh on view rebuild — the
    /// outer `primaryAction` doesn't suffer this since it's evaluated
    /// inline). Also persists the pick as the per-Project default.
    case pickEditorFromMenuTapped(EditorID)
    case customEditorsTapped
    /// Header GV button tapped. Emits `.delegate(.gitViewerToggleRequested)`
    /// so `RootFeature` performs the flip through the same
    /// `.gitViewerToggledForCurrentWorktree` reducer branch that ⌘⇧G uses.
    /// Keeping the write on one path avoids the view-supplied visibility
    /// drifting from the catalog snapshot the reducer reads.
    case gitViewerToggleTapped
    case setProjectDefaultEditorTapped(projectID: ProjectID, editorID: EditorID?)
    /// Run script split-button — primary or menu activation. Phase 2.
    case runScriptTapped(scriptID: UUID, projectID: ProjectID, worktreeID: WorktreeID)
    /// "Manage Scripts…" menu footer or primary click on an empty script list.
    case manageScriptsTapped
    case delegate(Delegate)

    /// Parent-consumed delegate. `RootFeature` routes these into the existing
    /// `EditorFeature` / settings-sheet presentation paths.
    enum Delegate: Equatable {
      /// Request to open a Worktree. `editorID == nil` asks the parent to
      /// resolve the default via `EditorFeature.resolveDefault` and
      /// dispatch `.editor(.openRequested(...))` with the resolved id.
      case openEditor(editorID: EditorID?, worktreePath: String, projectID: ProjectID?)
      /// Present the Settings sheet on the editors tab (`"+ Custom editors…"`).
      case showCustomEditorsSettings
      /// Mirror of today's "Set default for this Project" sub-menu.
      case setProjectOverride(projectID: ProjectID, editorID: EditorID?)
      /// Dropdown menu pick: parent resolves the current Worktree's path
      /// from `state.selection` (avoids stale closure captures in NSMenuItem
      /// actions), persists `editorID` as the per-Project default, and opens
      /// the worktree with that editor.
      case pickEditorFromMenu(EditorID)
      /// GV button tapped. Parent flips the current Worktree's visibility
      /// via `.gitViewerToggledForCurrentWorktree` (shared with ⌘⇧G).
      case gitViewerToggleRequested
      /// Run a user-defined Project script. RootFeature dispatches to
      /// `HierarchyClient.runScript`.
      case runScriptRequested(scriptID: UUID, projectID: ProjectID, worktreeID: WorktreeID)
      /// User asked to manage scripts — open the Settings window. The Scripts
      /// pane is one click away in the Project's sub-rows; pane-level
      /// deep-link is intentionally out of scope for Phase 2 (see
      /// docs/exec-plans/project-settings-phase2.md Decision Log).
      case manageScriptsRequested
    }
  }

  @Dependency(HierarchyClient.self) var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .onAppear:
        return .none

      case .openDefaultEditorTapped(let path, let pid):
        return .send(.delegate(.openEditor(editorID: nil, worktreePath: path, projectID: pid)))

      case .openEditorTapped(let id, let path, let pid):
        return .send(.delegate(.openEditor(editorID: id, worktreePath: path, projectID: pid)))

      case .pickEditorFromMenuTapped(let id):
        return .send(.delegate(.pickEditorFromMenu(id)))

      case .customEditorsTapped:
        return .send(.delegate(.showCustomEditorsSettings))

      case .gitViewerToggleTapped:
        return .send(.delegate(.gitViewerToggleRequested))

      case .setProjectDefaultEditorTapped(let projectID, let editorID):
        return .send(
          .delegate(
            .setProjectOverride(
              projectID: projectID,
              editorID: editorID
            )))

      case .runScriptTapped(let scriptID, let projectID, let worktreeID):
        return .send(
          .delegate(
            .runScriptRequested(
              scriptID: scriptID,
              projectID: projectID,
              worktreeID: worktreeID
            )))

      case .manageScriptsTapped:
        return .send(.delegate(.manageScriptsRequested))

      case .delegate:
        // Consumed by the parent; reducer has no local state change.
        return .none
      }
    }
  }
}
