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
    /// C7 M3/M4 (0005): read-only git viewer hosted in the trailing
    /// inspector slot. Selection is forwarded by the `.selectionChanged`
    /// reducer branch so the feature always tracks the active Worktree.
    var gitViewer: GitViewerFeature.State = .init()
    /// C8 M6b (0005): editor preferences + per-Project override state.
    var editor: EditorFeature.State = .init()

    /// DEC-9 (M4, 2026-04-20): `true` shows the trailing inspector column
    /// (git diff/history viewer). `ContentView` hosts `GitViewerView` there
    /// once the 0005 M4a wiring lands.
    var inspectorVisible: Bool = false

    /// C8 M6b (0005): settings sheet presentation. `nil` = hidden; non-nil
    /// presents the sheet with a dedicated sub-feature state that mirrors
    /// a subset of `editor` for isolated in-sheet edits.
    @Presents var settingsSheet: SettingsSheetFeature.State?
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
    case settingsSheetShown
    case settingsSheet(PresentationAction<SettingsSheetFeature.Action>)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
    case gitViewer(GitViewerFeature.Action)
    case editor(EditorFeature.Action)
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
    Scope(state: \.gitViewer, action: \.gitViewer) {
      GitViewerFeature()
    }
    Scope(state: \.editor, action: \.editor) {
      EditorFeature()
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
        let tabID = resolveActiveTab(selection: selection)
        state.detail.splitViewport.activeTabID = tabID
        // Forward the (projectID, worktreeID) pair to GitViewerFeature so
        // the inspector always reflects the current selection.
        return .send(.gitViewer(.worktreeSelected(
          projectID: selection.projectID,
          worktreeID: selection.worktreeID
        )))

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

      case .gitViewer:
        return .none

      case .editor:
        return .none

      case .settingsSheetShown:
        state.settingsSheet = SettingsSheetFeature.State()
        return .none

      case .settingsSheet(.dismiss):
        state.settingsSheet = nil
        // Sheet edited its own EditorFeature state in isolation. The root's
        // EditorFeature (drives the Worktree-header dropdown + toast label) reads the same
        // underlying SettingsStore, but its in-memory cache is stale until we re-fetch.
        // Re-running onAppear is a cheap round-trip through describe + readSnapshot.
        return .send(.editor(.onAppear))

      case .settingsSheet:
        return .none

      case .inspectorVisibilityToggled:
        state.inspectorVisible.toggle()
        return .none
      }
    }
    .ifLet(\.$settingsSheet, action: \.settingsSheet) {
      SettingsSheetFeature()
    }
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
