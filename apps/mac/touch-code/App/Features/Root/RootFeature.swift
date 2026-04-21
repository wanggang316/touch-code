import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Root reducer for the TCA shell. Composes sub-features for the sidebar,
/// the worktree detail column, and top-level presentations. Also owns the
/// two long-running subscriptions that every feature depends on:
///   - `terminalClient.events()` — drives crash / exit / output lifecycle
///   - `hierarchyClient.selectionChanges()` — drives worktree-scoped
///     features (C7 diff viewer, M4 detail column swap)
///
/// T1 removed the T0-era `SidebarMode` plumbing (the sidebar unconditionally
/// renders the hierarchy tree; T2's Header bell is its own feature on
/// `WorktreeHeader`, not a reuse of `InboxSidebarFeature`). `InboxSidebar`
/// source files remain in the tree but are no longer mounted in `RootFeature`.
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

    var sidebar: HierarchySidebarFeature.State = .init()
    var detail: WorktreeDetailFeature.State = .init()
    /// C7 M3/M4 (0005): read-only git viewer hosted in the trailing
    /// inspector slot. Selection is forwarded by the `.selectionChanged`
    /// reducer branch so the feature always tracks the active Worktree.
    var gitViewer: GitViewerFeature.State = .init()
    /// C8 M6b (0005): editor preferences + per-Project override state.
    var editor: EditorFeature.State = .init()
    /// T2: Header feature (bell + Open-in split button + GV toggle).
    var worktreeHeader: WorktreeHeaderFeature.State = .init()

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
    case inspectorVisibilityToggled
    case settingsSheetShown
    case settingsSheet(PresentationAction<SettingsSheetFeature.Action>)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
    case gitViewer(GitViewerFeature.Action)
    case editor(EditorFeature.Action)
    case worktreeHeader(WorktreeHeaderFeature.Action)
  }

  nonisolated enum CancelID: Sendable { case events, selectionChanges }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(FinderClient.self) private var finderClient

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
    Scope(state: \.worktreeHeader, action: \.worktreeHeader) {
      WorktreeHeaderFeature()
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
        // Worst case for sidebar context-menu "Open in default editor" is an
        // empty descriptor cache → resolution falls through to
        // EditorRegistry.finderID, which is always installed. Priming via
        // `.send(.editor(.onAppear))` here was considered but was dropped
        // because it runs the live EditorService on a background Task and
        // the live factory's `MainActor.assumeIsolated { ... }` assertion
        // fails from a non-MainActor queue during test-host bootstrap. The
        // WorktreeHeaderOpenButton's own `.task { store.send(.onAppear) }`
        // is the canonical hydration path.

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

      // Sidebar delegate routing. Must come before the catch-all
      // `case .sidebar:` so the nested pattern matches first.

      case .sidebar(.delegate(.openInDefaultEditor(let path, let projectID))):
        // Inline default-editor resolution: project override → global default
        // → EditorRegistry.finderID. Each tier is accepted only if the
        // descriptor is installed. T2 will hoist this into
        // `EditorFeature.resolveDefault` when it rebases; keeping it inline
        // now avoids touching `EditorFeature.Action` (T2's boundary).
        let descriptors = state.editor.descriptors
        let globalDefault = state.editor.globalDefault
        let overrideID: EditorID? = projectID.flatMap { pid in
          let catalog = hierarchyClient.snapshot()
          for space in catalog.spaces {
            for project in space.projects where project.id == pid {
              return project.defaultEditor
            }
          }
          return nil
        }
        func installed(_ id: EditorID?) -> EditorID? {
          guard let id,
                descriptors.contains(where: { $0.id == id && $0.isInstalled })
          else { return nil }
          return id
        }
        let resolved: EditorID = installed(overrideID)
          ?? installed(globalDefault)
          ?? EditorRegistry.finderID
        return .send(.editor(.openRequested(
          editorID: resolved,
          worktreePath: path,
          projectID: projectID
        )))

      case .sidebar(.delegate(.revealInFinder(let path))):
        let client = finderClient
        return .run { _ in
          await MainActor.run { client.reveal(path) }
        }

      case .sidebar:
        return .none

      case .detail:
        return .none

      case .gitViewer:
        return .none

      case .editor:
        return .none

      case .worktreeHeader:
        // Delegate routing (open editor, settings sheet, project override)
        // lands in M6; for the interim the Scope keeps the feature alive and
        // the reducer self-handles everything except the delegate emit,
        // which is a parent-consumed no-op here.
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
