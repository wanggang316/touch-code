import ComposableArchitecture
import Foundation
import os.log
import TouchCodeCore

/// T2 reducer backing the Worktree Header row: branch label + notification
/// bell + Open-in split button + Git Viewer toggle.
///
/// Owns the cached inbox snapshot and the derived `unreadCount` that feeds
/// the bell badge. `unreadCount` is recomputed against the current catalog
/// snapshot (via `HierarchyClient.snapshot`) on every inbox and catalog
/// change, so badge count and popover row count share one `PanelID ->
/// WorktreeID` resolution — orphan notifications never inflate the badge.
///
/// User-facing side effects are kept in the reducer so TestStore can prove
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
    /// Catalog-resolvable total unread; drives the bell badge.
    var unreadCount: Int = 0
    /// Popover presentation state.
    var popoverOpen: Bool = false
  }

  enum Action: Equatable {
    case onAppear
    case inboxUpdated(NotificationInbox)
    case catalogChanged
    case popoverToggled(Bool)
    case dismissAllTapped
    case notificationTapped(spaceID: SpaceID, projectID: ProjectID, worktreeID: WorktreeID)
    case openDefaultEditorTapped(worktreePath: String, projectID: ProjectID?)
    case openEditorTapped(editorID: EditorID, worktreePath: String, projectID: ProjectID?)
    case customEditorsTapped
    case gitViewerToggled(worktreeID: WorktreeID, currentVisibility: Bool)
    case setProjectDefaultEditorTapped(spaceID: SpaceID, projectID: ProjectID, editorID: EditorID?)
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
      case setProjectOverride(projectID: ProjectID, spaceID: SpaceID, editorID: EditorID?)
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
        state.unreadCount = inbox.totalUnread(in: hierarchyClient.snapshot())
        return .none

      case .catalogChanged:
        state.unreadCount = state.inbox.totalUnread(in: hierarchyClient.snapshot())
        return .none

      case .popoverToggled(let open):
        state.popoverOpen = open
        return .none

      case .dismissAllTapped:
        inboxClient.clearAll()
        state.popoverOpen = false
        return .none

      case .notificationTapped(let spaceID, let projectID, let worktreeID):
        hierarchyClient.selectSpace(spaceID)
        do {
          try hierarchyClient.selectProject(projectID, spaceID)
          try hierarchyClient.selectWorktree(worktreeID, projectID, spaceID)
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

      case .customEditorsTapped:
        return .send(.delegate(.showCustomEditorsSettings))

      case .gitViewerToggled(let worktreeID, let currentVisibility):
        hierarchyClient.setWorktreeGitViewerVisible(worktreeID, !currentVisibility)
        return .none

      case .setProjectDefaultEditorTapped(let spaceID, let projectID, let editorID):
        return .send(.delegate(.setProjectOverride(
          projectID: projectID,
          spaceID: spaceID,
          editorID: editorID
        )))

      case .delegate:
        // Consumed by the parent; reducer has no local state change.
        return .none
      }
    }
  }
}
