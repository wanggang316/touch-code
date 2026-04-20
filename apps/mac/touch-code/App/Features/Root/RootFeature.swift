import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Root reducer for the TCA shell. Composes sub-features for the sidebar,
/// the worktree detail column, and top-level presentations. Also owns the
/// two long-running subscriptions that every feature depends on:
///   - `terminalClient.events()` — drives crash / exit / output lifecycle
///   - `hierarchyClient.selectionChanges()` — drives worktree-scoped
///     features (C6 inbox filter, C7 diff viewer, M4 detail column swap)
///
/// Sub-feature Scopes for M3 (`HierarchySidebarFeature`) and M4
/// (`WorktreeDetailFeature`) are intentionally commented out — their state
/// types don't exist yet. The wiring is a one-line drop-in when they land.
/// Which sidebar content the leading column renders. Per DEC-2, C6
/// (agent-notification inbox) ships as an alternate mode in the leading
/// column rather than a third NavigationSplitView column. The toggle lives
/// on `RootFeature` because multiple features may dispatch it (keyboard
/// shortcut, C6-originated "new notifications" pulse, menu item).
nonisolated enum SidebarMode: String, Equatable, CaseIterable, Sendable {
  case hierarchy
  case inbox
}

@Reducer
struct RootFeature {
  @ObservableState
  struct State: Equatable {
    /// Most recent `HierarchySelection` seen from the stream. Features read
    /// this instead of holding a HierarchyManager reference.
    var selection: HierarchySelection = .empty

    /// Most recent engine event — diagnostic only in M2; M3/M4 features
    /// observe the stream directly via child-feature subscriptions.
    var lastEvent: LastEventMarker?

    /// DEC-2: leading column toggles between `HierarchySidebarView` and
    /// the C6 inbox placeholder.
    var sidebarMode: SidebarMode = .hierarchy

    var sidebar: HierarchySidebarFeature.State = .init()
    var detail: WorktreeDetailFeature.State = .init()

    /// DEC-9 (M4, 2026-04-20): reserved for C7 M3/M4. `true` shows the
    /// trailing inspector column (git diff/history viewer). Placeholder
    /// view for now; C7 plan wires the reducer + real view.
    var inspectorVisible: Bool = false

    @Presents var newSpaceSheet: NewSpaceFeature.State?
    @Presents var newTabSheet: NewTabFeature.State?
    @Presents var confirmAlert: AlertState<ConfirmAlertAction>?

    // Reserved for C8 M6 (editor settings). The C8 plan will define a
    // `SettingsFeature` and replace this placeholder type with its State.
    // Keeping the @Presents slot reserved here avoids restructuring root
    // state when C8 lands (DEC-4):
    //   @Presents var settingsSheet: SettingsFeature.State?
  }

  /// Opaque marker for diagnostic logging / tests — the full `TerminalEvent`
  /// is not Equatable (Data payloads in panelOutput), so we store a coarse
  /// discriminator.
  enum LastEventMarker: Equatable {
    case panelCreated
    case panelReady
    case panelOutput
    case panelExited
    case panelCrashed
    case panelClosedByTab
    case panelIdle
    case tabActivated
    case tabAutoClosed
    case worktreeActivated
    case hierarchyMutated

    init(_ event: TerminalEvent) {
      switch event {
      case .panelCreated: self = .panelCreated
      case .panelReady: self = .panelReady
      case .panelOutput: self = .panelOutput
      case .panelIdle: self = .panelIdle
      case .panelExited: self = .panelExited
      case .panelCrashed: self = .panelCrashed
      case .panelClosedByTab: self = .panelClosedByTab
      case .tabActivated: self = .tabActivated
      case .tabAutoClosed: self = .tabAutoClosed
      case .worktreeActivated: self = .worktreeActivated
      case .hierarchyMutated: self = .hierarchyMutated
      }
    }
  }

  enum Action: Equatable {
    case onLaunch
    case onQuit
    case selectionChanged(HierarchySelection)
    case engineEventReceived(LastEventMarker)
    case sidebarModeChanged(SidebarMode)
    case inspectorVisibilityToggled
    case newSpaceButtonTapped
    case newTabButtonTapped
    case removeWorktreeButtonTapped(WorktreeID, ProjectID, SpaceID)
    case newSpaceSheet(PresentationAction<NewSpaceFeature.Action>)
    case newTabSheet(PresentationAction<NewTabFeature.Action>)
    case confirmAlert(PresentationAction<ConfirmAlertAction>)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
  }

  enum ConfirmAlertAction: Equatable {
    case confirmRemoveWorktree(WorktreeID, ProjectID, SpaceID)
  }

  nonisolated enum CancelID: Sendable { case events, selectionChanges }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Scope(state: \.sidebar, action: \.sidebar) {
      HierarchySidebarFeature()
    }
    Scope(state: \.detail, action: \.detail) {
      WorktreeDetailFeature()
    }

    Reduce { state, action in
      switch action {
      case .onLaunch:
        let eventStream = terminalClient.events()
        let selectionStream = hierarchyClient.selectionChanges()
        return .merge(
          .run { send in
            for await event in eventStream {
              await send(.engineEventReceived(LastEventMarker(event)))
            }
          }
          .cancellable(id: CancelID.events, cancelInFlight: true),

          .run { send in
            for await selection in selectionStream {
              await send(.selectionChanged(selection))
            }
          }
          .cancellable(id: CancelID.selectionChanges, cancelInFlight: true)
        )

      case .onQuit:
        return .merge(
          .cancel(id: CancelID.events),
          .cancel(id: CancelID.selectionChanges)
        )

      case .selectionChanged(let selection):
        state.selection = selection
        // Mirror the selection's active tab into the split viewport so M5
        // lazy-surface lifecycle can react without reading HierarchyManager
        // from a reducer. Tab is resolved on-the-fly from the catalog.
        //
        // TEST CONTRACT: any TestStore that sends `.selectionChanged` MUST
        // override `hierarchyClient.snapshot` — the default `testValue`
        // traps on invocation. Return `Catalog(windows: [], spaces: [],
        // selectedSpaceID: nil)` for the common nil-selection case.
        let tabID = resolveActiveTab(selection: selection)
        state.detail.splitViewport.activeTabID = tabID
        return .none

      case .engineEventReceived(let marker):
        state.lastEvent = marker
        return .none

      case .sidebarModeChanged(let mode):
        state.sidebarMode = mode
        return .none

      case .sidebar:
        return .none

      case .detail:
        return .none

      case .inspectorVisibilityToggled:
        state.inspectorVisible.toggle()
        return .none

      case .newSpaceButtonTapped:
        state.newSpaceSheet = NewSpaceFeature.State()
        return .none

      case .newTabButtonTapped:
        guard
          let spaceID = state.selection.spaceID,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        state.newTabSheet = NewTabFeature.State(
          spaceID: spaceID, projectID: projectID, worktreeID: worktreeID
        )
        return .none

      case .removeWorktreeButtonTapped(let worktreeID, let projectID, let spaceID):
        state.confirmAlert = AlertState {
          TextState("Remove Worktree")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemoveWorktree(worktreeID, projectID, spaceID)) {
            TextState("Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("Removing a Worktree closes all its Tabs and their Panels. The on-disk git worktree is NOT removed in this build.")
        }
        return .none

      case .confirmAlert(.presented(.confirmRemoveWorktree(let worktreeID, let projectID, let spaceID))):
        try? hierarchyClient.removeWorktree(worktreeID, projectID, spaceID)
        return .none

      case .confirmAlert:
        return .none

      case .newSpaceSheet, .newTabSheet:
        return .none
      }
    }
    .ifLet(\.$newSpaceSheet, action: \.newSpaceSheet) {
      NewSpaceFeature()
    }
    .ifLet(\.$newTabSheet, action: \.newTabSheet) {
      NewTabFeature()
    }
    .ifLet(\.$confirmAlert, action: \.confirmAlert)
  }

  /// Resolve the active tab for a selection using the snapshot from the
  /// hierarchy client. The snapshot is synchronously available because
  /// `HierarchyClient.snapshot` forwards `hierarchyManager.catalog` which
  /// is updated on the MainActor before `selectionChanges` yields.
  private func resolveActiveTab(selection: HierarchySelection) -> TabID? {
    let catalog = hierarchyClient.snapshot()
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let space = catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return nil }
    return worktree.selectedTabID
  }
}
