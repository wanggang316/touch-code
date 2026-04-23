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
    /// 0012: GitHub integration — per-Worktree PR snapshots + popover state.
    var gitHub: GitHubFeature.State = .init()
    /// 0008: router for tab/split intents decoded from ghostty keybinds.
    var panelActionRouter: PanelActionRouterFeature.State = .init()
    /// 0008: router for window/app-level intents decoded from ghostty keybinds.
    var windowActionRouter: WindowActionRouterFeature.State = .init()

    /// T4: space manager sheet presentation. `nil` = hidden; non-nil
    /// presents the sheet for managing (list / rename / reorder / delete) Spaces.
    @Presents var spaceManagerSheet: SpaceManagerFeature.State?

    /// Command Palette overlay presentation. `nil` = hidden; non-nil
    /// renders the floating search card on top of the main split. Cleared
    /// on activation (the child emits `.delegate(.activate(…))`, the root
    /// routes it to a feature action and nils this slot in the same tick).
    @Presents var commandPalette: CommandPaletteFeature.State?

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
    /// Toggle the Command Palette overlay. Sources: `⌘P` menu binding
    /// (source panel unknown — payload is `nil`), and
    /// `panelActionRouter(.delegate(.commandPaletteToggleRequested(panelID)))`
    /// forwarded from the ghostty keybind pipeline (payload carries the
    /// source panel so Panel-scoped palette actions target the right
    /// split).
    case commandPaletteToggle(PanelID?)
    case commandPalette(PresentationAction<CommandPaletteFeature.Action>)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
    case gitViewer(GitViewerFeature.Action)
    case editor(EditorFeature.Action)
    case worktreeHeader(WorktreeHeaderFeature.Action)
    case gitHub(GitHubFeature.Action)
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

  /// Child-feature scopes. Split from `body` so Swift's type inference budget stays under
  /// the single-expression limit — each additional top-level `Scope` in `body` adds to the
  /// inferred return type and past ~7 scopes the compiler fails with "unable to type-check
  /// in reasonable time".
  @ReducerBuilder<State, Action>
  private var sidebarAndDetailScopes: some Reducer<State, Action> {
    Scope(state: \.sidebar, action: \.sidebar) { HierarchySidebarFeature() }
    Scope(state: \.detail, action: \.detail) { WorktreeDetailFeature() }
    Scope(state: \.gitViewer, action: \.gitViewer) { GitViewerFeature() }
  }

  @ReducerBuilder<State, Action>
  private var headerAndEditorScopes: some Reducer<State, Action> {
    Scope(state: \.editor, action: \.editor) { EditorFeature() }
    Scope(state: \.worktreeHeader, action: \.worktreeHeader) { WorktreeHeaderFeature() }
    Scope(state: \.gitHub, action: \.gitHub) {
      GitHubFeature()
      GitHubRootBindings()
    }
  }

  @ReducerBuilder<State, Action>
  private var routerScopes: some Reducer<State, Action> {
    Scope(state: \.panelActionRouter, action: \.panelActionRouter) { PanelActionRouterFeature() }
    Scope(state: \.windowActionRouter, action: \.windowActionRouter) { WindowActionRouterFeature() }
  }

  var body: some Reducer<State, Action> {
    sidebarAndDetailScopes
    headerAndEditorScopes
    routerScopes
    coreReducer
  }

  /// The large `Reduce { state, action in switch action { ... } }` block that wires root
  /// lifecycle, cross-feature action forwarding, and delegate handling. Split from `body`
  /// to keep the result-builder expression under the Swift type-inference budget.
  private var coreReducer: some Reducer<State, Action> {
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
        let priorProjectID = state.selection.projectID
        state.selection = selection
        // Mirror the selection's active tab into the split viewport so M5
        // lazy-surface lifecycle can react without reading HierarchyManager
        // from a reducer. Tab is resolved on-the-fly from the catalog.
        let tabID = resolveActiveTab(selection: selection)
        state.detail.splitViewport.activeTabID = tabID
        // Forward the (projectID, worktreeID) pair to GitViewerFeature so
        // the inspector always reflects the current selection.
        var effects: [Effect<Action>] = [
          .send(
            .gitViewer(
              .worktreeSelected(
                projectID: selection.projectID,
                worktreeID: selection.worktreeID
              )))
        ]
        // v2 GitHub integration (0013 M4): when the active Project changes, ask
        // GitHubFeature to batch-fetch PR data for every branch in that Project.
        // The reducer runs one `gh api graphql` for the whole repo instead of
        // N per-Worktree calls — see docs/exec-plans/0013-github-integration-batched.md.
        if selection.projectID != priorProjectID,
          let projectID = selection.projectID,
          let project = lookupProject(
            projectID: projectID, spaceID: selection.spaceID
          ),
          let gitRootString = project.gitRoot {
          let gitRoot = URL(fileURLWithPath: gitRootString)
          let pairs = project.worktrees.compactMap { worktree -> GitHubFeature.Action.WorktreeBranchPair? in
            guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty else {
              return nil
            }
            return GitHubFeature.Action.WorktreeBranchPair(
              worktreeID: worktree.id, branch: branch
            )
          }
          effects.append(
            .send(
              .gitHub(
                .projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: pairs)
              ))
          )
        }
        return .merge(effects)

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
        // Compute the focus target BEFORE mutating the tree so the
        // leaf identity is still valid. Matches ghostty's macOS
        // controller: closing the leftmost leaf → focus next; otherwise
        // → focus previous. Returns nil for the last leaf in a tab.
        let catalog = hierarchyClient.snapshot()
        let focusTarget: PanelID? = catalog
          .spaces.first(where: { $0.id == address.spaceID })?
          .projects.first(where: { $0.id == address.projectID })?
          .worktrees.first(where: { $0.id == address.worktreeID })?
          .tabs.first(where: { $0.id == address.tabID })?
          .splitTree.focusTargetAfterClosing(panelID)
        try? hierarchyClient.closePanel(
          panelID, address.tabID, address.worktreeID, address.projectID,
          address.spaceID
        )
        if let focusTarget {
          return .run { [client = hierarchyClient] _ in
            await MainActor.run {
              client.focusSurfaceView(focusTarget)
            }
          }
        }
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

      // 0012: GitHub integration delegate actions. Detailed handling (openURL →
      // NSWorkspace.open, showSettingsGitHub → SettingsWindowPresenter, pullRequestMerged
      // → M7 post-merge Worktree action) moves into `GitHubRootBindings` stacked under the
      // gitHub scope — leaving the inline case a no-op keeps this reducer's switch-body
      // small enough for Swift's type-inference budget.
      case .gitHub:
        return .none

      // 0008: panel-action router delegate actions.
      // `commandPaletteToggleRequested` forwards the ghostty keybind
      // pipeline into the palette's top-level toggle. `presentTerminal`
      // stays an explicit no-op — the sidebar/detail focus flow already
      // handles active-worktree swaps.
      case .panelActionRouter(.delegate(.commandPaletteToggleRequested(let panelID))):
        return .send(.commandPaletteToggle(panelID))
      case .panelActionRouter(.delegate(.presentTerminalRequested)):
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

      case .commandPaletteToggle(let sourcePanelID):
        if state.commandPalette == nil {
          state.commandPalette = CommandPaletteFeature.State()
          let selection = state.selection
          let catalog = hierarchyClient.snapshot()
          let descriptors = state.editor.descriptors
          let recency = CommandPaletteRecencyPersistence.load()
          // Menu-triggered palette opens have no source panel; fall back
          // to the first leaf of the selected tab's split tree so Window-
          // scoped actions still resolve to the correct NSWindow.
          // Panel-scoped palette items that depend on real focus are
          // omitted by the builder when the source is a leaf fallback.
          let resolvedPanelID = sourcePanelID
            ?? CommandPaletteItems.resolveFocusedPanelID(
              selection: selection, catalog: catalog
            )
          let panelSourceIsPrecise = sourcePanelID != nil
          return .send(
            .commandPalette(
              .presented(
                .appeared(
                  selection, catalog, descriptors, recency,
                  resolvedPanelID, panelSourceIsPrecise
                )
              )
            )
          )
        } else {
          // Closing without activating: persist any pruning the child
          // did on `.appeared` so stale entries don't re-surface on the
          // next open. Activation path already persists via the
          // `.activate` branch above.
          if let recency = state.commandPalette?.recency {
            CommandPaletteRecencyPersistence.save(recency)
          }
          state.commandPalette = nil
          return .none
        }

      case .commandPalette(.presented(.delegate(.activate(let kind)))):
        if let recency = state.commandPalette?.recency {
          CommandPaletteRecencyPersistence.save(recency)
        }
        let sourcePanelID = state.commandPalette?.focusedPanelID
        state.commandPalette = nil
        return route(kind, state: &state, sourcePanelID: sourcePanelID)

      case .commandPalette(.dismiss):
        state.commandPalette = nil
        return .none

      case .commandPalette:
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
    .ifLet(\.$commandPalette, action: \.commandPalette) {
      CommandPaletteFeature()
    }
  }

  // swiftlint:disable cyclomatic_complexity
  /// Dispatches a Command Palette activation into the feature action
  /// that already implements the command. Every case forwards into a
  /// pre-existing action or client — the palette invents no new
  /// behavior.
  private func route(
    _ kind: CommandPaletteItem.Kind,
    state: inout State,
    sourcePanelID: PanelID?
  ) -> Effect<Action> {
    switch kind {
    // App
    case .openSettings:
      let presenter = settingsWindowPresenter
      return .run { _ in await MainActor.run { presenter.open() } }
    case .checkForUpdates:
      return .send(.windowActionRouter(.requested(.checkForUpdates)))
    case .quit:
      return .send(.windowActionRouter(.requested(.quit)))

    // Spaces
    case .selectSpace(let id):
      return .send(.sidebar(.spaceRowTapped(id)))
    case .openSpaceManager:
      return .send(.spaceManagerSheetShown)
    case .switchToSpaceAtIndex(let n):
      return .send(.switchToSpaceAtIndex(n))

    // Worktree
    case .selectWorktree(let spaceID, let projectID, let worktreeID):
      return .send(
        .sidebar(.worktreeRowTapped(worktreeID, inProject: projectID, inSpace: spaceID))
      )
    case .closeCurrentWorktree:
      guard let spaceID = state.selection.spaceID,
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
      else { return .none }
      let catalog = hierarchyClient.snapshot()
      let name = catalog
        .spaces.first(where: { $0.id == spaceID })?
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?.name ?? ""
      return .send(
        .sidebar(
          .worktreeRemoveTapped(
            worktreeID: worktreeID, inProject: projectID, inSpace: spaceID, name: name
          )
        )
      )
    case .refreshCurrentWorktree:
      guard let spaceID = state.selection.spaceID,
            let projectID = state.selection.projectID
      else { return .none }
      return .run { [projectReconciler] _ in
        await projectReconciler.reconcile(projectID: projectID, spaceID: spaceID)
      }
    case .toggleGitViewer:
      return .send(.gitViewerToggledForCurrentWorktree)

    // Editor
    case .openCurrentWorktreeInDefaultEditor:
      return .send(.openDefaultForCurrentWorktreeRequested)
    case .openCurrentWorktreeIn(let editorID):
      guard let spaceID = state.selection.spaceID,
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
      else { return .none }
      let catalog = hierarchyClient.snapshot()
      guard let path = catalog
        .spaces.first(where: { $0.id == spaceID })?
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?.path
      else { return .none }
      return .send(
        .editor(
          .openRequested(
            editorID: editorID, worktreePath: path, projectID: projectID
          )
        )
      )
    case .revealCurrentWorktreeInFinder:
      guard let spaceID = state.selection.spaceID,
            let projectID = state.selection.projectID,
            let worktreeID = state.selection.worktreeID
      else { return .none }
      let catalog = hierarchyClient.snapshot()
      guard let path = catalog
        .spaces.first(where: { $0.id == spaceID })?
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?.path
      else { return .none }
      let client = finderClient
      return .run { _ in await MainActor.run { client.reveal(path) } }

    // Panel / Window — thin wrappers over the routers
    case .panelAction(let req):
      guard let panelID = sourcePanelID
        ?? CommandPaletteItems.resolveFocusedPanelID(
          selection: state.selection, catalog: hierarchyClient.snapshot()
        )
      else { return .none }
      return .send(.panelActionRouter(.requested(panelID, req)))
    case .windowAction(let req):
      return .send(.windowActionRouter(.requested(req)))
    }
  }
  // swiftlint:enable cyclomatic_complexity

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

  /// Locates a `Project` in the current catalog snapshot by `(projectID, spaceID)`.
  /// `spaceID` narrows the search when present — useful for selection payloads that
  /// carry both; walks every Space otherwise so stale selection payloads still resolve
  /// under in-place catalog mutations.
  private func lookupProject(projectID: ProjectID, spaceID: SpaceID?) -> Project? {
    let catalog = hierarchyClient.snapshot()
    if let spaceID,
      let space = catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }) {
      return project
    }
    for space in catalog.spaces {
      if let project = space.projects.first(where: { $0.id == projectID }) {
        return project
      }
    }
    return nil
  }

}
