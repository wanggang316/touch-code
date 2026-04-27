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
    /// 0014: titlebar-center Worktree Status Bar — owns only the transient
    /// toast slot; PR / motivational forms are view-level projections.
    var statusBar: StatusBarFeature.State = .init()
    /// 0008: router for tab/split intents decoded from ghostty keybinds.
    var paneActionRouter: PaneActionRouterFeature.State = .init()
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

    /// M9: lifecycle-script toast presentation. `nil` = hidden; non-nil
    /// shows the transient sheet with the running / completed script
    /// output anchored to the main window.
    @Presents var lifecycleScriptToast: LifecycleScriptToastFeature.State?

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
  /// is not Equatable (Data payloads in paneOutput), so we store a coarse
  /// discriminator.
  enum LastEventMarker: Equatable {
    case paneCreated
    case paneReady
    case paneOutput
    case paneExited
    case paneCrashed
    case paneClosedByTab
    case paneIdle
    case tabActivated
    case tabAutoClosed
    case worktreeActivated
    case hierarchyMutated
    case paneInfoChanged
    case paneActionRequested
    case windowActionRequested
    case configChanged

    init(_ event: TerminalEvent) {
      switch event {
      case .paneCreated: self = .paneCreated
      case .paneReady: self = .paneReady
      case .paneOutput: self = .paneOutput
      case .paneIdle: self = .paneIdle
      case .paneExited: self = .paneExited
      case .paneCrashed: self = .paneCrashed
      case .paneClosedByTab: self = .paneClosedByTab
      case .tabActivated: self = .tabActivated
      case .tabAutoClosed: self = .tabAutoClosed
      case .worktreeActivated: self = .worktreeActivated
      case .hierarchyMutated: self = .hierarchyMutated
      case .paneInfoChanged: self = .paneInfoChanged
      case .paneActionRequested: self = .paneActionRequested
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
    /// binding, or crash). The root reducer resolves the pane's address
    /// and calls `hierarchyClient.closePane` to drop the catalog entry.
    case paneLifecycleExited(PaneID)
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
    /// Tab-bar uplift: `⌘T` menu binding. Resolves the current Worktree
    /// and forwards `.detail(.tabBar(.newTabButtonTapped))`.
    case newTabForCurrentWorktree
    /// `⌘W` menu binding — closes the Worktree's active tab via
    /// `.detail(.tabBar(.closeButtonTapped))`. Silent no-op when no tab
    /// is active.
    case closeActiveTabForCurrentWorktree
    /// `⌥⌘1..⌥⌘9` menu bindings — selects the Nth tab (1-indexed).
    /// Silent no-op when the index exceeds the tab count.
    case selectTabAtIndexForCurrentWorktree(Int)
    /// `⌘⇧[` / `⌘⇧]` menu bindings — jumps to the previous / next tab
    /// with wrap-around. Calls `HierarchyClient.selectAdjacentTab`
    /// directly since the traversal logic lives in `HierarchyManager`.
    case selectAdjacentTabForCurrentWorktree(TabAdjacency)
    /// T3: ⌘K entry point. Forwards to the sidebar so its Space-switcher
    /// popover opens. Handled inline by the root reducer as a `.send` into
    /// `.sidebar(.externalSpacePopoverOpenRequested)`.
    case openSpaceSwitcherRequested
    /// $EDITOR routing. Dispatched from `EditorFeature.delegate.openShellEditorRequested`
    /// when any editor-open path resolves the preferred id to `EditorRegistry.shellEditorID`.
    /// Locates the target Worktree by path, creates a fresh Tab, and spawns a Pane with
    /// `initialCommand: "$EDITOR"` so the Pane primitive handles the launch the way
    /// `EditorService.open` cannot (no Pane/Tab context in the service signature).
    case openShellEditorInWorktree(worktreePath: String, projectID: ProjectID?)
    case spaceManagerSheetShown
    case spaceManagerSheet(PresentationAction<SpaceManagerFeature.Action>)
    case switchToSpaceAtIndex(Int)
    /// Toggle the Command Palette overlay. Sources: `⌘P` menu binding
    /// (source pane unknown — payload is `nil`), and
    /// `paneActionRouter(.delegate(.commandPaletteToggleRequested(paneID)))`
    /// forwarded from the ghostty keybind pipeline (payload carries the
    /// source pane so Pane-scoped palette actions target the right
    /// split).
    case commandPaletteToggle(PaneID?)
    case commandPalette(PresentationAction<CommandPaletteFeature.Action>)
    /// M9: surfaces a lifecycle-script result on the main window.
    /// Sources: Add Worktree (setup), sidebar Archive (archive),
    /// sidebar Remove (delete). The originating feature already ran
    /// the wrapper variant and got the `LifecycleScriptResult` back;
    /// this action presents the toast in its terminal state. Skipped
    /// results (empty script) are silent — the toast does not show.
    case runWorktreeLifecycleResult(
      phase: SettingsWriter.WorktreeLifecycle,
      worktreeName: String,
      result: LifecycleScriptResult
    )
    case lifecycleScriptToast(PresentationAction<LifecycleScriptToastFeature.Action>)
    case sidebar(HierarchySidebarFeature.Action)
    case detail(WorktreeDetailFeature.Action)
    case gitViewer(GitViewerFeature.Action)
    case editor(EditorFeature.Action)
    case worktreeHeader(WorktreeHeaderFeature.Action)
    case gitHub(GitHubFeature.Action)
    case statusBar(StatusBarFeature.Action)
    case paneActionRouter(PaneActionRouterFeature.Action)
    case windowActionRouter(WindowActionRouterFeature.Action)
  }

  nonisolated enum CancelID: Sendable {
    case events, selectionChanges, projectReconcileFocus
  }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(FinderClient.self) private var finderClient
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(ProjectReconciler.self) private var projectReconciler
  @Dependency(SettingsWindowPresenter.self) private var settingsWindowPresenter
  @Dependency(GitHubSnapshotCacheClient.self) private var gitHubSnapshotCache

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
    Scope(state: \.statusBar, action: \.statusBar) { StatusBarFeature() }
  }

  @ReducerBuilder<State, Action>
  private var routerScopes: some Reducer<State, Action> {
    Scope(state: \.paneActionRouter, action: \.paneActionRouter) { PaneActionRouterFeature() }
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
              case .paneActionRequested(let paneID, let request):
                await send(.paneActionRouter(.requested(paneID, request)))
              case .windowActionRequested(let request):
                await send(.windowActionRouter(.requested(request)))
              case .paneExited(let paneID, _, _):
                // ghostty's `close_surface` binding + child-exit both land
                // here. Surface memory is already freed by the engine; we
                // still need to remove the Pane from the catalog so the
                // SplitTree collapses and no stale black rect is rendered.
                await send(.paneLifecycleExited(paneID))
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
          .cancellable(id: CancelID.projectReconcileFocus, cancelInFlight: true),

          // 0013 M4 follow-up: hydrate the GitHub integration's in-memory state from
          // its on-disk snapshot cache so the sidebar paints PR badges on the first
          // render pass, without the blank-then-populated flash the user sees when
          // the first `gh api graphql` round-trip is the only data source. Walks the
          // live catalog once to build the branch→worktreeID map the reducer needs
          // to project cached branches into per-Worktree snapshot state.
          .run { [cache = gitHubSnapshotCache, client = hierarchyClient] send in
            let cached = cache.load()
            guard !cached.isEmpty else { return }
            let catalog = await MainActor.run { client.snapshot() }
            var pairsByProject: [ProjectID: [GitHubFeature.Action.WorktreeBranchPair]] = [:]
            for space in catalog.spaces {
              for project in space.projects {
                let pairs = project.worktrees.compactMap {
                  worktree -> GitHubFeature.Action.WorktreeBranchPair? in
                  guard !worktree.archived, let branch = worktree.branch, !branch.isEmpty
                  else { return nil }
                  return GitHubFeature.Action.WorktreeBranchPair(
                    worktreeID: worktree.id, branch: branch
                  )
                }
                if !pairs.isEmpty { pairsByProject[project.id] = pairs }
              }
            }
            await send(
              .gitHub(.seedFromCache(cached: cached, branchPairsByProject: pairsByProject))
            )
          }
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
        // Auto-seed a Tab + Pane when the selected Worktree has none so
        // switching to a brand-new Worktree immediately shows a live
        // terminal rooted at `worktree.path` instead of a placeholder that
        // forces the user to click twice. Safe to run unconditionally on
        // every selection change: createTab/openPane are no-ops when the
        // Worktree already has tabs/panes (we gate on .isEmpty below).
        autoSeedTabAndPaneIfNeeded(for: selection)
        // Mirror the selection's active tab into the split viewport so M5
        // lazy-surface lifecycle can react without reading HierarchyManager
        // from a reducer. Tab is resolved on-the-fly from the catalog.
        let tabID = resolveActiveTab(selection: selection)
        state.detail.splitViewport.activeTabID = tabID
        // Eagerly rebuild `paneHosts` for the new selection in the SAME
        // reducer tick, with warm ghostty surfaces pre-attached. SwiftUI's
        // next render then finds a fully populated `.ready` host array —
        // no ProgressView scope-miss frame, no "Creating surface…"
        // placeholder frame. The existing `.task(id:)` sync in
        // `SplitViewportView` stays as a fallback for paths that don't go
        // through `selectionChanged` (TabBar tap within the same worktree,
        // pane open / split / close inside the active tab).
        reconcilePaneHosts(
          &state.detail.splitViewport, selection: selection, tabID: tabID
        )
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
          let gitRootString = project.gitRoot
        {
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

      case .paneLifecycleExited(let paneID):
        // Resolve the pane's address from the live catalog (the engine
        // already unregistered the surface, but the catalog still holds
        // the Pane entity here). Address can be nil if a racing teardown
        // dropped the pane first — then there's nothing to do.
        guard let address = hierarchyClient.addressOf(paneID) else {
          return .none
        }
        let catalog = hierarchyClient.snapshot()
        guard
          let tab = catalog
            .spaces.first(where: { $0.id == address.spaceID })?
            .projects.first(where: { $0.id == address.projectID })?
            .worktrees.first(where: { $0.id == address.worktreeID })?
            .tabs.first(where: { $0.id == address.tabID })
        else { return .none }
        // Single-pane tab: ⌘W's `close_surface` should also retire the now-empty
        // tab. Leaving a zombie tab with no panes shows a blank pane area and
        // makes the window look broken. `closeTab` is a no-op for the surface
        // (already torn down by the engine) but does the catalog cleanup and
        // routes selection to the adjacent tab.
        if tab.panes.count <= 1 {
          try? hierarchyClient.closeTab(
            address.tabID, address.worktreeID, address.projectID, address.spaceID
          )
          return .none
        }
        // Multi-pane tab: drop the pane and transfer focus to the survivor.
        // Compute the focus target BEFORE mutating the tree so the leaf
        // identity is still valid. Matches ghostty's macOS controller:
        // closing the leftmost leaf → focus next; otherwise → focus previous.
        let focusTarget = tab.splitTree.focusTargetAfterClosing(paneID)
        try? hierarchyClient.closePane(
          paneID, address.tabID, address.worktreeID, address.projectID,
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

      case .sidebar(.delegate(.lifecycleScriptResult(let phase, let name, let result))):
        return .send(.runWorktreeLifecycleResult(phase: phase, worktreeName: name, result: result))

      case .sidebar:
        return .none

      case .detail:
        return .none

      case .gitViewer:
        return .none

      // 0014 M2: surface editor-open outcomes in the titlebar status bar.
      // The child `Scope(state: \.editor, ...)` has already mutated
      // `lastOpenResult`; we only fan a toast out. Success shows the chosen
      // editor's display name; failure shows a scrubbed one-line reason.
      case .editor(.openSucceeded(_, let displayName)):
        return .send(.statusBar(.push(.success("Opened in \(displayName)"))))

      case .editor(.openFailed(let reason)):
        return .send(.statusBar(.push(.warning(Self.shortToastMessage(reason)))))

      case .editor(.delegate(.openShellEditorRequested(let worktreePath, let projectID))):
        return .send(
          .openShellEditorInWorktree(worktreePath: worktreePath, projectID: projectID))

      case .editor:
        return .none

      case .worktreeHeader(.delegate(let delegate)):
        switch delegate {
        case .openEditor(let editorID, let worktreePath, let projectID):
          // An explicit pick from the "Open in ▾" submenu is strict; absent that, fall to
          // the shared resolver which returns nil when nothing is installed so the service
          // cascades through the priority list (see `resolveInstalledPreference`).
          let preferred: EditorID? =
            editorID
            ?? EditorFeature.resolveInstalledPreference(
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

        case .runScriptRequested(let scriptID, let projectID, let worktreeID):
          let client = hierarchyClient
          let presenter = settingsWindowPresenter
          return .run { send in
            do {
              try await client.runScript(scriptID, projectID, worktreeID)
            } catch let error as RunScriptError {
              await send(.statusBar(.push(.warning(Self.runScriptErrorMessage(error)))))
              _ = presenter  // Settings is not auto-opened on failure; user can navigate themselves.
            } catch {
              await send(.statusBar(.push(.warning("Run script failed: \(error.localizedDescription)"))))
            }
          }

        case .manageScriptsRequested:
          let presenter = settingsWindowPresenter
          return .run { _ in await MainActor.run { presenter.open() } }
        }

      case .worktreeHeader:
        return .none

      // 0014 M3: surface gh mutation outcomes in the status bar. The child
      // `Scope(state: \.gitHub, ...)` has already updated `mutating` / `lastError`;
      // we only fan a toast out. Message format mirrors the sidebar popover's
      // verb so cross-surface language stays consistent.
      case .gitHub(.mergeCompleted(_, let prNumber, .success)):
        return .send(.statusBar(.push(.success("PR #\(prNumber) merged"))))
      case .gitHub(.closeCompleted(_, .success)):
        return .send(.statusBar(.push(.success("PR closed"))))
      case .gitHub(.markReadyCompleted(_, .success)):
        return .send(.statusBar(.push(.success("PR marked ready"))))
      case .gitHub(.rerunFailedJobsCompleted(_, .success)):
        return .send(.statusBar(.push(.success("Re-ran failed jobs"))))

      // Failure cases keep the verb prefix so the user can tell merge / close /
      // mark-ready / rerun-failed-jobs apart in the warning toast.
      case .gitHub(.mergeCompleted(_, _, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Merge failed: \(reason)"))))
      case .gitHub(.closeCompleted(_, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Close failed: \(reason)"))))
      case .gitHub(.markReadyCompleted(_, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Mark ready failed: \(reason)"))))
      case .gitHub(.rerunFailedJobsCompleted(_, .failure(let error))):
        let reason = Self.shortToastMessage(String(describing: error))
        return .send(.statusBar(.push(.warning("Rerun failed: \(reason)"))))

      // 0012: GitHub integration delegate actions. Detailed handling (openURL →
      // NSWorkspace.open, showSettingsGitHub → SettingsWindowPresenter, pullRequestMerged
      // → M7 post-merge Worktree action) moves into `GitHubRootBindings` stacked under the
      // gitHub scope — leaving the inline case a no-op keeps this reducer's switch-body
      // small enough for Swift's type-inference budget.
      case .gitHub:
        return .none

      // 0014: status-bar child scope is self-contained (toast slot + timers).
      // Cross-feature toast emission (editor open, gh mutation completion) lands
      // in subsequent milestones as additional cases BEFORE this catch-all.
      case .statusBar:
        return .none

      // 0008: pane-action router delegate actions.
      // `commandPaletteToggleRequested` forwards the ghostty keybind
      // pipeline into the palette's top-level toggle. `presentTerminal`
      // stays an explicit no-op — the sidebar/detail focus flow already
      // handles active-worktree swaps.
      case .paneActionRouter(.delegate(.commandPaletteToggleRequested(let paneID))):
        return .send(.commandPaletteToggle(paneID))
      case .paneActionRouter(.delegate(.presentTerminalRequested)):
        return .none

      case .paneActionRouter:
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

      case .commandPaletteToggle(let sourcePaneID):
        if state.commandPalette == nil {
          state.commandPalette = CommandPaletteFeature.State()
          let selection = state.selection
          let catalog = hierarchyClient.snapshot()
          let descriptors = state.editor.descriptors
          let recency = CommandPaletteRecencyPersistence.load()
          // Menu-triggered palette opens have no source pane; fall back
          // to the first leaf of the selected tab's split tree so Window-
          // scoped actions still resolve to the correct NSWindow.
          // Pane-scoped palette items that depend on real focus are
          // omitted by the builder when the source is a leaf fallback.
          let resolvedPaneID =
            sourcePaneID
            ?? CommandPaletteItems.resolveFocusedPaneID(
              selection: selection, catalog: catalog
            )
          let paneSourceIsPrecise = sourcePaneID != nil
          return .send(
            .commandPalette(
              .presented(
                .appeared(
                  selection, catalog, descriptors, recency,
                  resolvedPaneID, paneSourceIsPrecise
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
        let sourcePaneID = state.commandPalette?.focusedPaneID
        state.commandPalette = nil
        return route(kind, state: &state, sourcePaneID: sourcePaneID)

      case .commandPalette(.dismiss):
        state.commandPalette = nil
        return .none

      case .commandPalette:
        return .none

      case .runWorktreeLifecycleResult(let phase, let worktreeName, let result):
        switch result {
        case .skipped:
          // Empty script — no toast needed.
          return .none
        case .success, .failure:
          // "Latest wins" replacement: a fresh result while a toast is
          // presenting overwrites the previous state. The auto-dismiss
          // task on a previous .success uses `cancelInFlight: true`, so
          // the prior timer is cancelled when the new .finished arm
          // re-arms it. A failure toast carries no timer, so a new
          // success toast simply schedules its own dismiss against the
          // new presentation.
          state.lifecycleScriptToast = LifecycleScriptToastFeature.State(
            phase: phase, worktreeName: worktreeName
          )
          return .send(.lifecycleScriptToast(.presented(.finished(result))))
        }

      case .lifecycleScriptToast(.presented(.dismiss)),
        .lifecycleScriptToast(.dismiss):
        state.lifecycleScriptToast = nil
        return .none

      case .lifecycleScriptToast:
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

      case .openShellEditorInWorktree(let worktreePath, let projectIDHint):
        let catalog = hierarchyClient.snapshot()
        guard
          let address = Self.findWorktreeAddress(
            worktreePath: worktreePath, projectIDHint: projectIDHint, in: catalog)
        else {
          return .send(
            .editor(.openFailed(reason: "Could not locate worktree at \(worktreePath)")))
        }
        let (spaceID, projectID, worktreeID) = address
        guard
          let tabID = try? hierarchyClient.createTab(worktreeID, projectID, spaceID, nil)
        else {
          return .send(.editor(.openFailed(reason: "Could not create tab for $EDITOR")))
        }
        guard
          (try? hierarchyClient.openPane(
            tabID, worktreeID, projectID, spaceID, worktreePath, "$EDITOR")) != nil
        else {
          return .send(.editor(.openFailed(reason: "Could not spawn $EDITOR pane")))
        }
        // Bring the user to the freshly spawned Pane. Selecting after the catalog
        // mutation lets `autoSeedTabAndPaneIfNeeded` (driven by selectionChanges)
        // see the populated tab and skip its own seed.
        hierarchyClient.selectSpace(spaceID)
        try? hierarchyClient.selectProject(projectID, spaceID)
        try? hierarchyClient.selectWorktree(worktreeID, projectID, spaceID)
        try? hierarchyClient.selectTab(tabID, worktreeID, projectID, spaceID)
        return .send(
          .editor(.openSucceeded(editorID: EditorRegistry.shellEditorID, displayName: "$EDITOR")))

      case .openSpaceSwitcherRequested:
        return .send(.sidebar(.externalSpacePopoverOpenRequested))

      case .newTabForCurrentWorktree:
        guard
          let spaceID = state.selection.spaceID,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        return .send(
          .detail(
            .tabBar(
              .newTabButtonTapped(
                inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
              ))))

      case .closeActiveTabForCurrentWorktree:
        guard
          let spaceID = state.selection.spaceID,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .spaces.first(where: { $0.id == spaceID })?
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let activeTabID = worktree.selectedTabID,
          let activeTab = worktree.tabs.first(where: { $0.id == activeTabID })
        else { return .none }
        // Multi-pane tab: ⌘W closes just the focused pane, leaving the tab
        // open with its remaining panes (matches iTerm/Terminal.app). Single
        // (or zero) pane: fall through and close the whole tab.
        if activeTab.panes.count > 1 {
          let focusID = hierarchyClient.lastFocusedPane(activeTabID)
            ?? activeTab.splitTree.leaves().first
          if let focusID {
            try? hierarchyClient.closePane(
              focusID, activeTabID, worktreeID, projectID, spaceID
            )
          }
          return .none
        }
        return .send(
          .detail(
            .tabBar(
              .closeButtonTapped(
                activeTabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
              ))))

      case .selectTabAtIndexForCurrentWorktree(let n):
        guard
          n >= 1,
          let spaceID = state.selection.spaceID,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog
            .spaces.first(where: { $0.id == spaceID })?
            .projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          n <= worktree.tabs.count
        else { return .none }
        let targetTabID = worktree.tabs[n - 1].id
        return .send(
          .detail(
            .tabBar(
              .tabButtonTapped(
                targetTabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
              ))))

      case .selectAdjacentTabForCurrentWorktree(let direction):
        guard
          let spaceID = state.selection.spaceID,
          let projectID = state.selection.projectID,
          let worktreeID = state.selection.worktreeID
        else { return .none }
        // Selection mutation lives in HierarchyManager — no TabBarFeature
        // action to forward since there's no TabID to look up yet.
        _ = try? hierarchyClient.selectAdjacentTab(direction, worktreeID, projectID, spaceID)
        return .none
      }
    }
    .ifLet(\.$spaceManagerSheet, action: \.spaceManagerSheet) {
      SpaceManagerFeature()
    }
    .ifLet(\.$commandPalette, action: \.commandPalette) {
      CommandPaletteFeature()
    }
    .ifLet(\.$lifecycleScriptToast, action: \.lifecycleScriptToast) {
      LifecycleScriptToastFeature()
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
    sourcePaneID: PaneID?
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
      let name =
        catalog
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
      guard
        let path = catalog
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
      guard
        let path = catalog
          .spaces.first(where: { $0.id == spaceID })?
          .projects.first(where: { $0.id == projectID })?
          .worktrees.first(where: { $0.id == worktreeID })?.path
      else { return .none }
      let client = finderClient
      return .run { _ in await MainActor.run { client.reveal(path) } }

    // Project scripts (Phase 2 / M10) — palette item carries the
    // (projectID, worktreeID, scriptID) triple, fan out into the same
    // run-script effect the WorktreeHeader split-button and the Scripts
    // pane Run button use, so failure handling stays in one place.
    case .runProjectScript(let projectID, let worktreeID, let scriptID):
      let client = hierarchyClient
      return .run { send in
        do {
          try await client.runScript(scriptID, projectID, worktreeID)
        } catch let error as RunScriptError {
          await send(.statusBar(.push(.warning(Self.runScriptErrorMessage(error)))))
        } catch {
          await send(.statusBar(.push(.warning("Run script failed: \(error.localizedDescription)"))))
        }
      }

    // Pane / Window — thin wrappers over the routers
    case .paneAction(let req):
      guard
        let paneID = sourcePaneID
          ?? CommandPaletteItems.resolveFocusedPaneID(
            selection: state.selection, catalog: hierarchyClient.snapshot()
          )
      else { return .none }
      return .send(.paneActionRouter(.requested(paneID, req)))
    case .windowAction(let req):
      return .send(.windowActionRouter(.requested(req)))
    }
  }
  // swiftlint:enable cyclomatic_complexity

  /// Per-Project editor override, if any. Used to resolve the Header's
  /// default-editor dispatch through `EditorFeature.resolveDefault` without
  /// the reducer needing to hold a second cache of the catalog. v3 moved
  /// the override off catalog.json; read via `SettingsWriter`'s sync
  /// snapshot closure (itself MainActor-assumed internally).
  private func projectOverrideEditorID(for projectID: ProjectID?) -> EditorID? {
    guard let projectID else { return nil }
    return settingsWriter.readSnapshotSync().projects[projectID]?.defaultEditor
  }

  /// Walks `catalog` to find the `(SpaceID, ProjectID, WorktreeID)` triple whose Worktree
  /// has the given path. Used by the `.openShellEditorInWorktree` handler to recover
  /// the full address from the path-only handoff that propagates through the editor
  /// open chain. The optional `projectIDHint` short-circuits the project loop when the
  /// caller already knows the parent.
  nonisolated static func findWorktreeAddress(
    worktreePath: String,
    projectIDHint: ProjectID?,
    in catalog: Catalog
  ) -> (SpaceID, ProjectID, WorktreeID)? {
    for space in catalog.spaces {
      for project in space.projects {
        if let hint = projectIDHint, project.id != hint { continue }
        if let worktree = project.worktrees.first(where: { $0.path == worktreePath }) {
          return (space.id, project.id, worktree.id)
        }
      }
    }
    return nil
  }

  /// Ensures the selected Worktree has at least one Tab, and the active
  /// Tab has at least one Pane. Both spawn with `cwd = worktree.path` so
  /// the terminal lands in the correct directory. Idempotent: skips when
  /// the Worktree already has tabs / the tab already has panes.
  ///
  /// Runs on every `.selectionChanged`. Mutations do not change the
  /// selection tuple `(space, project, worktree)`, so the downstream
  /// stream does not re-fire and there is no loop.
  private func autoSeedTabAndPaneIfNeeded(for selection: HierarchySelection) {
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID
    else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let space = catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else { return }
    let cwd = worktree.path
    if worktree.tabs.isEmpty {
      guard let tabID = try? hierarchyClient.createTab(worktreeID, projectID, spaceID, nil)
      else { return }
      _ = try? hierarchyClient.openPane(tabID, worktreeID, projectID, spaceID, cwd, nil)
      return
    }
    let activeTabID = worktree.selectedTabID ?? worktree.tabs.first?.id
    guard let activeTabID,
      let tab = worktree.tabs.first(where: { $0.id == activeTabID }),
      tab.panes.isEmpty
    else { return }
    _ = try? hierarchyClient.openPane(activeTabID, worktreeID, projectID, spaceID, cwd, nil)
  }

  /// Rebuilds `SplitViewportFeature.State.paneHosts` for the selection's
  /// active Tab in the same reducer tick, eagerly marking entries `.ready`
  /// when the engine already holds a live surface for the pane. Without
  /// this, the first render after a Worktree switch sees a stale
  /// `paneHosts` (still keyed by the previous Worktree's PaneIDs), which
  /// forces `LeafView`'s `store.scope(...)` lookup to return nil and
  /// render a `ProgressView` placeholder — the visible "flash" on
  /// cross-Worktree navigation. Preserving entries carried from the prior
  /// selection keeps any pending `.failed` / `.retry` state intact when
  /// the same pane re-enters the viewport (e.g. tab-bar cycle).
  private func reconcilePaneHosts(
    _ splitViewport: inout SplitViewportFeature.State,
    selection: HierarchySelection,
    tabID: TabID?
  ) {
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let tabID
    else {
      splitViewport.paneHosts = []
      return
    }
    let catalog = hierarchyClient.snapshot()
    guard
      let tab = catalog
        .spaces.first(where: { $0.id == spaceID })?
        .projects.first(where: { $0.id == projectID })?
        .worktrees.first(where: { $0.id == worktreeID })?
        .tabs.first(where: { $0.id == tabID })
    else {
      splitViewport.paneHosts = []
      return
    }
    let existing = splitViewport.paneHosts
    splitViewport.paneHosts = IdentifiedArray(
      uniqueElements: tab.panes.map { pane in
        if let carry = existing[id: pane.id] { return carry }
        var seeded = PaneHostFeature.State(
          paneID: pane.id,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
          spaceID: spaceID
        )
        if let surface = terminalClient.surface(pane.id) {
          seeded.phase = .ready
          seeded.surface = SurfaceBox(surface: surface)
        }
        return seeded
      }
    )
  }

  /// Collapses a potentially multi-line error / warning string into a single
  /// status-bar-sized line. Keeps the first line (trimmed) and caps at 80
  /// characters so paths, tokens, and shell noise inside an `EditorError`
  /// don't bleed into the titlebar.
  ///
  /// The 80-char limit is not PII scrubbing per se — it's UX width. Upstream
  /// callers are responsible for not stuffing secrets into error messages;
  /// `EditorFeature.editorErrorDescription` already emits short friendly
  /// strings, so the truncation here is usually a no-op.
  static func shortToastMessage(_ raw: String) -> String {
    let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 80 else { return trimmed }
    let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 79)
    return String(trimmed[..<cutoff]) + "…"
  }

  static func runScriptErrorMessage(_ error: RunScriptError) -> String {
    switch error {
    case .unknownScript:
      return "Run script failed: script no longer exists"
    case .missingWorktree:
      return "Run script failed: worktree not available"
    case .missingProject:
      return "Run script failed: project not available"
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

  /// Locates a `Project` in the current catalog snapshot by `(projectID, spaceID)`.
  /// `spaceID` narrows the search when present — useful for selection payloads that
  /// carry both; walks every Space otherwise so stale selection payloads still resolve
  /// under in-place catalog mutations.
  private func lookupProject(projectID: ProjectID, spaceID: SpaceID?) -> Project? {
    let catalog = hierarchyClient.snapshot()
    if let spaceID,
      let space = catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID })
    {
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
