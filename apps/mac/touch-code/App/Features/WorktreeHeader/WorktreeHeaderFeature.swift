import ComposableArchitecture
import Foundation
import TouchCodeCore
import os.log

/// T2 reducer backing the Worktree Header row: branch label + notification
/// bell + Open-in split button + Git Viewer toggle.
///
/// Owns the cached inbox snapshot (from `InboxClient.observe()`) and the
/// popover presentation bit. The bell badge count is **not** cached in
/// state — views compute it via `State.unreadCount(in:)` passing the live
/// `hierarchyManager.catalog` at render time. That keeps the badge and
/// the popover grouping (which also reads the live catalog via
/// `@Environment`) on one `PaneID -> WorktreeID` resolution *and* makes
/// the badge react to catalog mutations (e.g. a Worktree being removed)
/// without the reducer needing a separate `.catalogChanged` action.
///
/// User-facing side effects stay in the reducer so TestStore can prove
/// them. Editor opens are emitted as `.delegate(.openEditor(...))` rather
/// than dispatched through `EditorClient` directly; `RootFeature` forwards
/// them into `EditorFeature.openRequested` (resolving `editorID: nil` via
/// `EditorFeature.resolveDefault` first).
@Reducer
struct WorktreeHeaderFeature {
  @ObservableState
  struct State: Equatable {
    /// Latest snapshot from `InboxClient.observe()`. `.empty` until `.onAppear`.
    var inbox: NotificationInbox = .empty
    /// Popover presentation state.
    var popoverOpen: Bool = false

    /// Catalog-resolvable total unread, computed against the caller-supplied
    /// catalog. Views call this with the live `hierarchyManager.catalog`;
    /// reducers can read it via `hierarchyClient.snapshot()`. Returning a
    /// computed value rather than a stored field avoids a cache-invalidation
    /// axis and guarantees badge / popover parity at the
    /// `paneWorktreeIndex` level.
    func unreadCount(in catalog: Catalog) -> Int {
      inbox.totalUnread(in: catalog)
    }
  }

  enum Action: Equatable {
    case onAppear
    case inboxUpdated(NotificationInbox)
    case popoverToggled(Bool)
    case dismissAllTapped
    case notificationTapped(projectID: ProjectID, worktreeID: WorktreeID)
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

  nonisolated enum CancelID: Sendable { case observe }

  @Dependency(InboxClient.self) var inboxClient
  @Dependency(HierarchyClient.self) var hierarchyClient

  private static let logger = Logger(subsystem: "com.touch-code.header", category: "bell")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let stream = inboxClient.observe()
        return .run { send in
          for await snapshot in stream {
            await send(.inboxUpdated(snapshot))
          }
        }
        .cancellable(id: CancelID.observe, cancelInFlight: true)

      case .inboxUpdated(let inbox):
        state.inbox = inbox
        return .none

      case .popoverToggled(let open):
        state.popoverOpen = open
        return .none

      case .dismissAllTapped:
        inboxClient.clearAll()
        state.popoverOpen = false
        return .none

      case .notificationTapped(let projectID, let worktreeID):
        do {
          try hierarchyClient.selectProject(projectID)
          try hierarchyClient.selectWorktree(worktreeID, projectID)
        } catch {
          Self.logger.error(
            "Stale popover row; selection chain failed: \(String(describing: error))"
          )
        }
        inboxClient.markReadForWorktree(worktreeID, hierarchyClient.snapshot())
        state.popoverOpen = false
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
