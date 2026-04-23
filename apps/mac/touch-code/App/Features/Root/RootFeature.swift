import AppKit
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
    /// 0008: router for tab/split intents decoded from ghostty keybinds.
    var panelActionRouter: PanelActionRouterFeature.State = .init()
    /// 0008: router for window/app-level intents decoded from ghostty keybinds.
    var windowActionRouter: WindowActionRouterFeature.State = .init()

    /// T4: space manager sheet presentation. `nil` = hidden; non-nil
    /// presents the sheet for managing (list / rename / reorder / delete) Spaces.
    @Presents var spaceManagerSheet: SpaceManagerFeature.State?

    /// T3: live read of the current Worktree's `gitViewerVisible` against
    /// a catalog snapshot. Not a cached field — views pass in
    /// `hierarchyManager.catalog` so SwiftUI's `@Observable` tracking
    /// re-renders on catalog mutation from any writer (⌘⇧G, Header GV
    /// button, external API). This avoids the state-divergence risk of
    /// caching the value on State: both toggle entry points write through
    /// `HierarchyClient.setWorktreeGitViewerVisible`, and the view reads
    /// the authoritative catalog each render.
    func gitViewerOverlayVisible(in catalog: Catalog) -> Bool {
      guard
        let spaceID = selection.spaceID,
        let projectID = selection.projectID,
        let worktreeID = selection.worktreeID,
        let space = catalog.spaces.first(where: { $0.id == spaceID }),
        let project = space.projects.first(where: { $0.id == projectID }),
        let worktree = project.worktrees.first(where: { $0.id == worktreeID })
      else { return false }
      return worktree.gitViewerVisible
    }
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
    case panelInfoChanged
    case panelActionRequested
    case windowActionRequested
    case configChanged

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
      case .panelInfoChanged: self = .panelInfoChanged
      case .panelActionRequested: self = .panelActionRequested
      case .windowActionRequested: self = .windowActionRequested
      case .configChanged: self = .configChanged
      }
    }
  }

  enum Action: Equatable {
    case onLaunch
    case onQuit
    case selectionChanged(HierarchySelection)
    case engineEventReceived(LastEventMarker)
    /// Emitted from the event stream when libghostty reports a surface
    /// has exited (child died, user-initiated close via `close_surface`
    /// binding, or crash). The root reducer resolves the panel's address
    /// and calls `hierarchyClient.closePanel` to drop the catalog entry.
    case panelLifecycleExited(PanelID)
    /// T3: Toggles the Git Viewer overlay for the current Worktree.
    /// Sources: Header GV button (T2) + ⌘⇧G (T3 Commands). Optimistically
    /// flips `state.gitViewerOverlayVisible` and fires
    /// `HierarchyClient.setWorktreeGitViewerVisible` to persist.
    case gitViewerToggledForCurrentWorktree
    /// T3: ⌘E entry point. Resolves the current Worktree's path from the
    /// catalog snapshot (via `hierarchyClient` — reducer-scoped dependency,
    /// unlike SwiftUI `Commands` structs where `@Dependency` falls through
    /// to `liveValue` and crashes on the stubbed `snapshot` accessor) and
    /// dispatches `.editor(.openDefaultInCurrentWorktreeRequested)`.
    case openDefaultForCurrentWorktreeRequested
    /// T3: ⌘K entry point. Forwards to the sidebar so its Space-switcher
    /// popover opens. Handled inline by the root reducer as a `.send` into
    /// `.sidebar(.externalSpacePopoverOpenRequested)`.
    case openSpaceSwitcherRequested
    case spaceManagerSheetShown
    case spaceManagerSheet(PresentationAction<SpaceManagerFeature.Action>)
    case switchToSpaceAtIndex(Int)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
    case gitViewer(GitViewerFeature.Action)
    case editor(EditorFeature.Action)
    case worktreeHeader(WorktreeHeaderFeature.Action)
    case panelActionRouter(PanelActionRouterFeature.Action)
    case windowActionRouter(WindowActionRouterFeature.Action)
  }

  nonisolated enum CancelID: Sendable {
    case events, selectionChanges, projectReconcileFocus
  }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(FinderClient.self) private var finderClient
  @Dependency(ProjectReconciler.self) private var projectReconciler
  @Dependency(SettingsWindowPresenter.self) private var settingsWindowPresenter

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
    Scope(state: \.panelActionRouter, action: \.panelActionRouter) {
      PanelActionRouterFeature()
    }
    Scope(state: \.windowActionRouter, action: \.windowActionRouter) {
      WindowActionRouterFeature()
    }

    Reduce { state, action in
      switch action {
      case .onLaunch:
        let eventStream = terminalClient.events()
        let selectionStream = hierarchyClient.selectionChanges()
        // `didBecomeActive` fires every time the app window re-gains focus;
        // per-run debounce lives inside `ProjectReconciler.reconcileAll`, so
        // click storms collapse into a single scan. The notification stream
        // via AsyncSequence is fine to hold for the full app lifetime;
        // `CancelID.projectReconcileFocus` stops it at quit.
        let focusStream = NotificationCenter.default.notifications(
          named: NSApplication.didBecomeActiveNotification
        )
        return .merge(
          .run { send in
            for await event in eventStream {
              // 0008: action-router events are routed to their dedicated
              // reducers; everything else just bumps the diagnostic marker.
              // Intent events also bump the marker so tests that observe
              // `lastEvent` still see them pass through.
              switch event {
              case .panelActionRequested(let panelID, let request):
                await send(.panelActionRouter(.requested(panelID, request)))
              case .windowActionRequested(let request):
                await send(.windowActionRouter(.requested(request)))
              case .panelExited(let panelID, _, _):
                // ghostty's `close_surface` binding + child-exit both land
                // here. Surface memory is already freed by the engine; we
                // still need to remove the Panel from the catalog so the
                // SplitTree collapses and no stale black rect is rendered.
                await send(.panelLifecycleExited(panelID))
              default:
                break
              }
              await send(.engineEventReceived(LastEventMarker(event)))
            }
          }
          .cancellable(id: CancelID.events, cancelInFlight: true),

          .run { send in
            for await selection in selectionStream {
              await send(.selectionChanged(selection))
            }
          }
          .cancellable(id: CancelID.selectionChanges, cancelInFlight: true),

          // Initial sweep: every persisted Project transitions out of .loading
          // once the reconciler fans out against the current snapshot.
          .run { [projectReconciler] _ in
            await projectReconciler.reconcileAll()
          },

          // Re-sync on window focus. Debounced inside the actor.
          .run { [projectReconciler] _ in
            for await _ in focusStream {
              await projectReconciler.reconcileAll()
            }
          }
          .cancellable(id: CancelID.projectReconcileFocus, cancelInFlight: true)
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
          .cancel(id: CancelID.selectionChanges),
          .cancel(id: CancelID.projectReconcileFocus)
        )

      case .selectionChanged(let selection):
        state.selection = selection
        // Mirror the selection's active tab into the split viewport so M5
        // lazy-surface lifecycle can react without reading HierarchyManager
        // from a reducer. Tab is resolved on-the-fly from the catalog.
        let tabID = resolveActiveTab(selection: selection)
        state.detail.splitViewport.activeTabID = tabID
        // Forward the (projectID, worktreeID) pair to GitViewerFeature so
        // the inspector always reflects the current selection. The Header
        // feature does not need a dispatched `.catalogChanged` signal —
        // its unread count is now computed from the live
        // `@Environment(HierarchyManager.self).catalog`, which re-renders
        // on any catalog mutation.
        return .send(
          .gitViewer(
            .worktreeSelected(
              projectID: selection.projectID,
              worktreeID: selection.worktreeID
            )))

      case .engineEventReceived(let marker):
        state.lastEvent = marker
        return .none

      case .panelLifecycleExited(let panelID):
        // Resolve the panel's address from the live catalog (the engine
        // already unregistered the surface, but the catalog still holds
        // the Panel entity here). Address can be nil if a racing teardown
        // dropped the panel first — then there's nothing to do.
        guard let address = hierarchyClient.addressOf(panelID) else {
          return .none
        }
        try? hierarchyClient.closePanel(
          panelID, address.tabID, address.worktreeID, address.projectID,
          address.spaceID
        )
        return .none

      // Sidebar delegate routing. Must come before the catch-all
      // `case .sidebar:` so the nested pattern matches first.

      case .sidebar(.delegate(.openInDefaultEditor(let path, let projectID))):
        // Route through the shared `resolveInstalledPreference` helper so the sidebar
        // context menu, the Header Open-in button, and the ⌘E shortcut use one resolution
        // path. When neither override nor global default is installed, pass `nil` so the
        // service's priority cascade picks the first installed editor (Cursor / Zed /
        // VSCode / …) before falling through to Finder. Passing `"finder"` here short-
        // circuits the priority walk because the service's `preferred` tier is strict.
        let preferred = EditorFeature.resolveInstalledPreference(
          projectOverride: projectOverrideEditorID(for: projectID),
          globalDefault: state.editor.globalDefault,
          descriptors: state.editor.descriptors
        )
        return .send(
          .editor(
            .openRequested(
              editorID: preferred,
              worktreePath: path,
              projectID: projectID
            )))

      case .sidebar(.delegate(.revealInFinder(let path))):
        let client = finderClient
        return .run { _ in
          await MainActor.run { client.reveal(path) }
        }

      case .sidebar(.delegate(.reconcileProjectRequested(let projectID, let spaceID))):
        // Kick the ProjectReconciler so the newly-added (or retried)
        // Project transitions through .loading → .ready (or .failed) and the
        // worktree list populates via T-WORKTREE's reconcileDiscoveredWorktrees
        // closure (once that PR lands; currently a no-op stub).
        return .run { _ in
          await projectReconciler.reconcile(projectID: projectID, spaceID: spaceID)
        }

      case .sidebar(.delegate(.revealExistingProject(let spaceID, let projectID))):
        // AddProjectFeature's "Reveal existing" banner fired — jump the user
        // to the already-registered row.
        hierarchyClient.selectSpace(spaceID)
        try? hierarchyClient.selectProject(projectID, spaceID)
        return .none

      case .sidebar(.delegate(.openSpaceManager)):
        return .send(.spaceManagerSheetShown)

      case .sidebar:
        return .none

      case .detail:
        return .none

      case .gitViewer:
        return .none

      case .editor:
        return .none

      case .worktreeHeader(.delegate(let delegate)):
        switch delegate {
        case .openEditor(let editorID, let worktreePath, let projectID):
          // An explicit pick from the "Open in ▾" submenu is strict; absent that, fall to
          // the shared resolver which returns nil when nothing is installed so the service
          // cascades through the priority list (see `resolveInstalledPreference`).
          let preferred: EditorID? = editorID ?? EditorFeature.resolveInstalledPreference(
            projectOverride: projectOverrideEditorID(for: projectID),
            globalDefault: state.editor.globalDefault,
            descriptors: state.editor.descriptors
          )
          return .send(
            .editor(
              .openRequested(
                editorID: preferred,
                worktreePath: worktreePath,
                projectID: projectID
              )))

        case .showCustomEditorsSettings:
          let presenter = settingsWindowPresenter
          return .run { _ in await MainActor.run { presenter.open() } }

        case .setProjectOverride(let projectID, let spaceID, let editorID):
          return .send(
            .editor(
              .setProjectOverride(
                projectID: projectID,
                spaceID: spaceID,
                editorID: editorID
              )))

        case .gitViewerToggleRequested:
          // Route through the same reducer branch ⌘⇧G uses so both entry
          // points share one write path (reads current visibility from the
          // catalog, writes the flipped value).
          return .send(.gitViewerToggledForCurrentWorktree)
        }

      case .worktreeHeader:
        return .none

      // 0008: panel-action router delegate actions. `presentTerminal` and
      // `toggleCommandPalette` don't have dedicated handlers in this
      // reducer yet — touch-code has no command-palette feature, and
      // the sidebar/detail focus flow already handles active-worktree
      // swaps. Consumed here as explicit no-ops so future integrations
      // can attach without re-touching the router.
      case .panelActionRouter(.delegate):
        return .none

      case .panelActionRouter:
        return .none

      case .windowActionRouter:
        return .none

      case .spaceManagerSheetShown:
        state.spaceManagerSheet = SpaceManagerFeature.State()
        return .none

      case .spaceManagerSheet(.dismiss):
        state.spaceManagerSheet = nil
        return .none

      case .spaceManagerSheet:
        return .none

      case .switchToSpaceAtIndex(let index):
        let snapshot = hierarchyClient.snapshot()
        guard index >= 1 && index <= snapshot.spaces.count else { return .none }
        let targetID = snapshot.spaces[index - 1].id
        return .send(.sidebar(.spaceRowTapped(targetID)))

      case .gitViewerToggledForCurrentWorktree:
        guard let worktreeID = state.selection.worktreeID else { return .none }
        // Read the current visibility from the live catalog — the view
        // layer's `State.gitViewerOverlayVisible(in:)` reads the same
        // source, so flipping from here and from the Header button
        // (which writes the catalog directly) can't diverge.
        let catalog = hierarchyClient.snapshot()
        let target = !state.gitViewerOverlayVisible(in: catalog)
        let setter = hierarchyClient.setWorktreeGitViewerVisible
        return .run { _ in
          await MainActor.run { setter(worktreeID, target) }
        }

      case .openDefaultForCurrentWorktreeRequested:
        guard
          let spaceID = state.selection.spaceID,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let path = catalog
            .spaces.first(where: { $0.id == spaceID })?
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })?.path
        else { return .none }
        return .send(
          .editor(
            .openDefaultInCurrentWorktreeRequested(
              spaceID: spaceID,
              projectID: projectID,
              worktreeID: worktreeID,
              worktreePath: path
            )))

      case .openSpaceSwitcherRequested:
        return .send(.sidebar(.externalSpacePopoverOpenRequested))
      }
    }
    .ifLet(\.$spaceManagerSheet, action: \.spaceManagerSheet) {
      SpaceManagerFeature()
    }
  }

  /// Per-Project editor override, if any. Used to resolve the Header's
  /// default-editor dispatch through `EditorFeature.resolveDefault` without
  /// the reducer needing to hold a second cache of the catalog.
  private func projectOverrideEditorID(for projectID: ProjectID?) -> EditorID? {
    guard let projectID else { return nil }
    let catalog = hierarchyClient.snapshot()
    for space in catalog.spaces {
      if let project = space.projects.first(where: { $0.id == projectID }) {
        return project.defaultEditor
      }
    }
    return nil
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
