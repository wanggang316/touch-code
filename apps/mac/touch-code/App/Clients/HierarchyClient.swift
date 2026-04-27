import ComposableArchitecture
import Foundation
import OSLog
import Observation
import TouchCodeCore

/// Logger for the background reconcile path. Matches the project's
/// `com.touch-code.<area>` subsystem convention (see SettingsStore,
/// CatalogStore, the IPC handlers, etc.). Category `reconcile` isolates
/// these events from the rest of the hierarchy subsystem so operators
/// can filter with `log stream --predicate 'category == "reconcile"'`.
private let reconcileLogger = Logger(
  subsystem: "com.touch-code.hierarchy",
  category: "reconcile"
)

/// TCA dependency-injection bridge over `HierarchyManager`. Features depend
/// on this struct's closures, not on the manager directly; the `liveValue`
/// binds each closure to a concrete `HierarchyManager` instance at app
/// startup via `.withDependencies`.
///
/// Narrow by design: every command is a one-line forward into the manager,
/// and `snapshot` plus `selectionChanges` provide the read paths TCA
/// features need without exposing the `@Observable` manager surface.
nonisolated struct HierarchyClient: Sendable {
  var createSpace: @MainActor @Sendable (_ name: String) -> SpaceID
  var renameSpace: @MainActor @Sendable (_ id: SpaceID, _ name: String) throws -> Void
  var removeSpace: @MainActor @Sendable (_ id: SpaceID) throws -> Void

  var addProject:
    @MainActor @Sendable (
      _ spaceID: SpaceID, _ name: String, _ rootPath: String, _ gitRoot: String?
    ) throws -> ProjectID
  var removeProject: @MainActor @Sendable (_ projectID: ProjectID, _ inSpace: SpaceID) throws -> Void
  var renameProject:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String
    ) throws -> Void

  var createWorktree:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String, _ path: String, _ branch: String?
    ) throws -> WorktreeID
  var removeWorktree:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void

  /// Records which Worktree to restore when the window re-activates this Space.
  /// `nil` clears. Missing space / unchanged value is a silent no-op — matches
  /// `HierarchyManager.setSpaceLastActiveWorktree` contract.
  var setSpaceLastActiveWorktree:
    @MainActor @Sendable (
      _ spaceID: SpaceID, _ worktreeID: WorktreeID?
    ) -> Void

  var selectSpace: @MainActor @Sendable (_ id: SpaceID?) -> Void
  var selectProject: @MainActor @Sendable (_ id: ProjectID?, _ inSpace: SpaceID) throws -> Void
  var selectWorktree:
    @MainActor @Sendable (
      _ id: WorktreeID?, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void

  var createTab:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID, _ name: String?
    ) throws -> TabID
  var closeTab:
    @MainActor @Sendable (
      _ id: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void
  var selectTab:
    @MainActor @Sendable (
      _ id: TabID?, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void

  // MARK: - Tab mutations (tab-bar uplift)

  var renameTab:
    @MainActor @Sendable (
      _ id: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
      _ name: String?
    ) throws -> Void
  var reorderTabs:
    @MainActor @Sendable (
      _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
      _ orderedIDs: [TabID]
    ) throws -> Void
  var closeOtherTabs:
    @MainActor @Sendable (
      _ keeping: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void
  var closeTabsToRight:
    @MainActor @Sendable (
      _ of: TabID,
      _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void
  var closeAllTabs:
    @MainActor @Sendable (
      _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void
  var selectAdjacentTab:
    @MainActor @Sendable (
      _ direction: TabAdjacency,
      _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> TabID?

  // MARK: - Runtime state (tab-bar uplift, M3)

  /// Read path for the chip's dirty (running-command) spinner. Always
  /// returns `false` until a writer — likely a C3 hook — starts calling
  /// `markPaneRunning` / `markPaneIdle`. The reader is exposed now so
  /// `TabChipLabel` can bind to it without another feature sweep.
  var tabIsDirty: @MainActor @Sendable (_ tabID: TabID) -> Bool
  /// Returns the Pane the user most recently focused in `tabID`, or nil.
  /// Mirrors `HierarchyManager.lastFocusedPane(in:)`.
  var lastFocusedPane: @MainActor @Sendable (_ tabID: TabID) -> PaneID?
  /// Dormant writer — calls `HierarchyManager.markPaneRunning`. No caller
  /// today; lands a real writer with the C3 hooks plan.
  var markPaneRunning: @MainActor @Sendable (_ paneID: PaneID) -> Void
  /// Dormant writer — calls `HierarchyManager.markPaneIdle`. No caller
  /// today; lands a real writer with the C3 hooks plan.
  var markPaneIdle: @MainActor @Sendable (_ paneID: PaneID) -> Void

  var openPane:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
      _ workingDirectory: String, _ initialCommand: String?
    ) throws -> PaneID
  var splitPane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: SplitTree<PaneID>.NewDirection,
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
      _ workingDirectory: String, _ initialCommand: String?
    ) throws -> PaneID
  var closePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ tabID: TabID, _ inWorktree: WorktreeID,
      _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void
  var focusPane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ tabID: TabID, _ inWorktree: WorktreeID,
      _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void
  /// View-level first-responder focus. Unlike `focusPane` this does
  /// NOT mutate the catalog (no zoom flag, no persistence) — it only
  /// asks the runtime to call `makeFirstResponder` on the pane's
  /// surface view. Used post-split (focus the new pane) and post-close
  /// (transfer focus to the surviving sibling per ghostty's policy).
  var focusSurfaceView: @MainActor @Sendable (_ paneID: PaneID) -> Void
  var resizeSplit:
    @MainActor @Sendable (
      _ path: SplitTree<PaneID>.Path, _ ratio: Double,
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) throws -> Void

  // Per-Project editor / worktrees-directory writers were retired in v3: the values
  // live on `Settings.projects[pid]` and every consumer routes through
  // `SettingsStore.mutateProject` (`SettingsWriter.setProjectDefaultEditor` /
  // `SettingsWriter.setProjectWorktreesDirectory`). HierarchyClient is read-only for
  // per-Project preferences (see `snapshot` / `kind`).

  /// Flips `Worktree.gitViewerVisible` for the given Worktree. Silent no-op on
  /// unknown `worktreeID`; persists through the standard debounced
  /// `store.scheduleSave(catalog)` pipeline (T0 §D5). Consumed by the T2
  /// Header Git Viewer toggle and by T3's overlay presentation binding.
  var setWorktreeGitViewerVisible:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ visible: Bool
    ) -> Void

  var snapshot: @MainActor @Sendable () -> Catalog

  /// Emits whenever the selection chain `(spaceID, projectID, worktreeID)`
  /// changes in the catalog. Deduped against the previous snapshot. Consumers
  /// (C6 inbox, C7 git-viewer, M4 detail-column swap) subscribe without
  /// needing a reference to the `@Observable` `HierarchyManager`. The stream
  /// finishes only when the engine shuts down.
  var selectionChanges: @MainActor @Sendable () -> AsyncStream<HierarchySelection>

  // MARK: - Worktree Management additions (feat/worktree-mgmt)

  /// Flips `Worktree.archived` for the given Worktree.
  var setWorktreeArchived:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ archived: Bool
    ) throws -> Void

  /// Flips `Worktree.isPinned` for the given Worktree. Silent for unknown ids / unchanged
  /// values. Persists via the standard debounced save pipeline.
  var setWorktreePinned:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ isPinned: Bool
    ) -> Void

  /// Flips `Project.isExpanded` (sidebar disclosure state). Silent no-op for
  /// unknown ids and unchanged values. Persists through the standard debounced
  /// save pipeline so the open / closed choice survives restart.
  var setProjectExpanded:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ isExpanded: Bool
    ) -> Void

  /// Reads the Project's git root, calls `GitWorktreeClient.lsWorktrees`
  /// off the main actor, and merges on-disk worktrees into the catalog.
  /// Append-only — never removes catalog rows. Swallows errors. Consumed
  /// by `ProjectReconciler` on feat/project-mgmt.
  var reconcileDiscoveredWorktrees:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID
    ) async -> Void

  /// Catalog-append step for Create Worktree.
  var createWorktreeWithGit:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID,
      _ branch: String, _ directoryName: String, _ path: String
    ) throws -> WorktreeID

  /// End-to-end Remove Worktree. Tears down all surfaces (panes /
  /// notifications) for the worktree, runs the git client's
  /// relocate-then-prune removal, then drops the catalog row. The git
  /// step sidesteps git's "uncommitted changes" and "submodule" guards
  /// by relocating the working dir before pruning, so this is a
  /// single-step destructive call — the caller's first confirmation
  /// dialog is the only protection.
  var removeWorktreeWithGit:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) async throws -> Void

  /// Forwards `HierarchyManager.runningPaneCount`.
  var runningPaneCount: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Int

  // MARK: - Project Management (pm) — added on feat/project-mgmt.

  /// Transient Project health signal. Written by `ProjectReconciler` only.
  var setProjectLoadState:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID, _ state: ProjectLoadState
    ) -> Void

  /// Reorder Projects inside a Space. Mirrors `ForEach.onMove`'s signature.
  var reorderProjects:
    @MainActor @Sendable (
      _ inSpace: SpaceID, _ from: IndexSet, _ to: Int
    ) throws -> Void

  /// Duplicate-add guard. Caller canonicalizes before querying.
  var isPathRegistered: @MainActor @Sendable (_ canonicalPath: String) -> (SpaceID, ProjectID)?

  /// Containing-project lookup (subdirectory-aware). Returns the deepest
  /// Project whose `rootPath` contains the canonical path (root or descendant).
  /// Used by the `editor.open` IPC so `tc open` inside a subdirectory still
  /// resolves the parent Project's default editor. Caller canonicalizes.
  var projectContaining: @MainActor @Sendable (_ canonicalPath: String) -> (SpaceID, ProjectID)?

  /// Derived `ProjectKind` lookup — scans every Space for the Project and
  /// returns its kind, or `nil` if the Project is not in the catalog. The
  /// Settings sidebar consults this to choose which sub-rows to render
  /// under a Project. Read-only; the app never writes kind — it flows from
  /// `gitRoot` set at project-discovery time.
  var kind: @MainActor @Sendable (_ projectID: ProjectID) -> ProjectKind?

  // MARK: - Space Management additions (feat/space-mgmt)

  /// Reorder Spaces using the IndexSet (source) and destination offset from
  /// SwiftUI's `.onMove(perform:)`. Silent no-op on empty IndexSet.
  var reorderSpaces: @MainActor @Sendable (_ source: IndexSet, _ destination: Int) -> Void

  // MARK: - Pane Action Routing (0008 M5)

  /// Resolves a `PaneID` to the hierarchy address needed to service
  /// pane-scoped intents (target resolution for `closeTab`, `moveTab`,
  /// `selectTab`, `equalizeTabSplits`, etc.). Returns `nil` when the pane
  /// is not in the catalog — expected during teardown races on the action
  /// callback thread.
  var addressOf: @MainActor @Sendable (PaneID) -> PaneAddress?

  /// Moves a Tab by a relative offset within its Worktree. Positive shifts
  /// right, negative shifts left. Clamped to the Worktree's tab-array
  /// bounds by `HierarchyManager.moveTab`.
  var moveTab:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ inSpace: SpaceID, _ offset: Int
    ) throws -> Void

  /// Sets every split node's ratio in the Tab's SplitTree to 0.5 so sibling
  /// panes render at equal sizes. Leaf-only trees are a silent no-op.
  var equalizeTabSplits:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ inSpace: SpaceID
    ) throws -> Void

  /// Resizes a Pane in the SplitTree along the given direction by `amount`.
  /// `amount` is interpreted as a ratio delta (clamped by SplitTree) — the
  /// ghostty RESIZE_SPLIT action carries pixel amounts but touch-code's
  /// tree only stores ratios.
  var resizePane:
    @MainActor @Sendable (
      _ paneID: PaneID, _ direction: ResizeDirection, _ amount: Double
    ) throws -> Void

  /// Clears the Tab's zoomed-pane flag. Paired with `focusPane` (which
  /// sets the zoom) to service `PaneActionRequest.toggleSplitZoom`.
  var unzoomTab:
    @MainActor @Sendable (
      _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID,
      _ inSpace: SpaceID
    ) throws -> Void

  // MARK: - Project Settings Phase 2

  /// Runs a user-defined `ScriptDefinition` from `Settings.projects[pid].scripts`.
  /// Looks up the script + worktree, opens a fresh tab whose name is the
  /// script's `displayName`, and types the script's `command` into the new
  /// pane's PTY. Project envVars get injected through the M8 spawn-path env
  /// hook. Throws `RunScriptError.unknownScript` when the id is not in the
  /// project's scripts (deleted between user click and effect dispatch);
  /// throws `RunScriptError.missingWorktree` when the worktree disappears.
  var runScript:
    @MainActor @Sendable (
      _ scriptID: UUID, _ projectID: ProjectID, _ worktreeID: WorktreeID
    ) async throws -> Void

  // MARK: - Worktree lifecycle wrappers (M9)

  /// Script-only entry for cases where the catalog row already exists —
  /// notably the Create Worktree flow, where `wt sw` creates the
  /// directory before the sidebar attaches the catalog row. Returns
  /// `.skipped` when the configured `git.<phase>Script` is empty.
  var runWorktreeLifecycleScript:
    @MainActor @Sendable (
      _ phase: SettingsWriter.WorktreeLifecycle,
      _ worktreeID: WorktreeID,
      _ projectID: ProjectID
    ) async -> LifecycleScriptResult

  /// Catalog-append step plus setup-script execution. On script failure the
  /// catalog row is rolled back; the on-disk directory is left for inspection.
  /// Mirrors `createWorktree` plus the lifecycle wrapper.
  var createWorktreeWithLifecycle:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID,
      _ name: String, _ path: String, _ branch: String?
    ) async throws -> (WorktreeID, LifecycleScriptResult)

  /// Sets `Worktree.archived` and (on `archived: true`) runs the archive
  /// script first. Fail-warn: a non-zero exit does not block the flag flip.
  var setWorktreeArchivedWithLifecycle:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ archived: Bool
    ) async throws -> LifecycleScriptResult

  /// Drops the catalog row and runs the delete script. Fail-warn: the row
  /// is removed regardless of script exit.
  var removeWorktreeWithLifecycle:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
    ) async throws -> LifecycleScriptResult

  // MARK: - Worktree sidebar ordering (worktree-sidebar-ordering.md task01)

  /// Reorder worktrees within a single sidebar segment under a Project.
  /// `from` is a segment-relative `IndexSet`; `to` is the segment-relative
  /// destination offset, both in SwiftUI `ForEach.onMove` convention. Out-of-
  /// range offsets, an out-of-range destination, or an empty `IndexSet`
  /// drop the whole reorder silently (staleness guard). Throws
  /// `HierarchyError.notFound` for unknown project ids.
  var reorderWorktrees:
    @MainActor @Sendable (
      _ projectID: ProjectID, _ inSpace: SpaceID,
      _ segment: WorktreeSegment, _ from: IndexSet, _ to: Int
    ) throws -> Void
}

enum RunScriptError: Error, Equatable, Sendable {
  case unknownScript(UUID)
  case missingWorktree(WorktreeID)
  case missingProject(ProjectID)
}

/// Full hierarchy address a `PaneID` resolves to. Carries the IDs of every
/// ancestor so `HierarchyClient` mutations that require the full chain
/// (`closeTab`, `selectTab`, `equalizeTabSplits`, …) can be called without a
/// second catalog walk.
nonisolated struct PaneAddress: Sendable, Equatable {
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let paneID: PaneID
}

/// Coarse selection payload. `nil` for any level means "no selection at that
/// level" — e.g. a Space may be selected with no Project chosen yet.
nonisolated struct HierarchySelection: Equatable, Sendable {
  let spaceID: SpaceID?
  let projectID: ProjectID?
  let worktreeID: WorktreeID?

  static let empty = HierarchySelection(spaceID: nil, projectID: nil, worktreeID: nil)
}

// MARK: - Live bridge

extension HierarchyClient {
  @MainActor
  // swiftlint:disable:next function_body_length
  static func live(
    manager: HierarchyManager,
    settings: SettingsStore? = nil,
    gitWorktreeClient: GitWorktreeClient = .makeLive()
  ) -> HierarchyClient {
    HierarchyClient(
      createSpace: { manager.createSpace(name: $0) },
      renameSpace: { try manager.renameSpace($0, name: $1) },
      removeSpace: { try manager.removeSpace($0) },
      addProject: { try manager.addProject(to: $0, name: $1, rootPath: $2, gitRoot: $3) },
      removeProject: { try manager.removeProject($0, from: $1) },
      renameProject: { projectID, spaceID, name in
        try manager.renameProject(projectID, in: spaceID, name: name)
      },
      createWorktree: { projectID, spaceID, name, path, branch in
        try manager.createWorktree(in: projectID, in: spaceID, name: name, path: path, branch: branch)
      },
      removeWorktree: { worktreeID, projectID, spaceID in
        try manager.removeWorktree(worktreeID, from: projectID, in: spaceID)
      },
      setSpaceLastActiveWorktree: { spaceID, worktreeID in
        manager.setSpaceLastActiveWorktree(spaceID: spaceID, worktreeID: worktreeID)
      },
      selectSpace: { manager.selectSpace($0) },
      selectProject: { try manager.selectProject($0, in: $1) },
      selectWorktree: { worktreeID, projectID, spaceID in
        try manager.selectWorktree(worktreeID, in: projectID, in: spaceID)
      },
      createTab: { worktreeID, projectID, spaceID, name in
        try manager.createTab(in: worktreeID, in: projectID, in: spaceID, name: name)
      },
      closeTab: { tabID, worktreeID, projectID, spaceID in
        try manager.closeTab(tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      selectTab: { tabID, worktreeID, projectID, spaceID in
        try manager.selectTab(tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      renameTab: { tabID, worktreeID, projectID, spaceID, name in
        try manager.renameTab(tabID, in: worktreeID, in: projectID, in: spaceID, name: name)
      },
      reorderTabs: { worktreeID, projectID, spaceID, orderedIDs in
        try manager.reorderTabs(
          in: worktreeID, in: projectID, in: spaceID, orderedIDs: orderedIDs)
      },
      closeOtherTabs: { keepID, worktreeID, projectID, spaceID in
        try manager.closeOtherTabs(
          keeping: keepID, in: worktreeID, in: projectID, in: spaceID)
      },
      closeTabsToRight: { pivotID, worktreeID, projectID, spaceID in
        try manager.closeTabsToRight(
          of: pivotID, in: worktreeID, in: projectID, in: spaceID)
      },
      closeAllTabs: { worktreeID, projectID, spaceID in
        try manager.closeAllTabs(in: worktreeID, in: projectID, in: spaceID)
      },
      selectAdjacentTab: { direction, worktreeID, projectID, spaceID in
        try manager.selectAdjacentTab(
          direction: direction, in: worktreeID, in: projectID, in: spaceID)
      },
      tabIsDirty: { tabID in manager.tabIsDirty(tabID) },
      lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) },
      markPaneRunning: { paneID in manager.markPaneRunning(paneID) },
      markPaneIdle: { paneID in manager.markPaneIdle(paneID) },
      openPane: { [weak settings] tabID, worktreeID, projectID, spaceID, cwd, initial in
        // Defensive guard against stale catalog state: when a worktree
        // is deleted outside the app (`git worktree remove`) before
        // reconcile catches up, libghostty crashes if it tries to spawn
        // a shell in a non-existent cwd. Reject here so callers'
        // `try?` swallows the error instead of bringing down the app.
        var isDir: ObjCBool = false
        guard
          FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
          isDir.boolValue
        else {
          throw HierarchyError.notFound("Worktree path missing: \(cwd)")
        }
        // M8: resolve project envVars from the SettingsStore so every
        // user-flow openPane (TabBar new-tab, SplitViewport new-tab,
        // CreateWorktree, IPC openPane) inherits Project-defined env. When
        // the live wiring omits a SettingsStore (legacy callers, headless
        // tests) the env defaults to empty and the pane spawns with the
        // raw process env — same behaviour as before M8.
        let env: [String: String] =
          settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) }
          ?? [:]
        return try manager.openPane(
          in: tabID, in: worktreeID, in: projectID, in: spaceID,
          workingDirectory: cwd, initialCommand: initial, env: env
        )
      },
      splitPane: { [weak settings] paneID, direction, tabID, worktreeID, projectID, spaceID, cwd, initial in
        // Splits inherit the same Project envVars as the parent pane —
        // the new pty is forked from a fresh shell, not the existing one,
        // so the env hook still has to run.
        let env: [String: String] =
          settings.map { HierarchyManager.resolvedEnv(for: projectID, in: $0.settings) }
          ?? [:]
        return try manager.splitPane(
          paneID, direction: direction,
          in: tabID, in: worktreeID, in: projectID, in: spaceID,
          workingDirectory: cwd, initialCommand: initial, env: env
        )
      },
      closePane: { paneID, tabID, worktreeID, projectID, spaceID in
        try manager.closePane(paneID, in: tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      focusPane: { paneID, tabID, worktreeID, projectID, spaceID in
        try manager.focusPane(paneID, in: tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      focusSurfaceView: { paneID in
        manager.focusSurfaceView(for: paneID)
      },
      resizeSplit: { path, ratio, tabID, worktreeID, projectID, spaceID in
        try manager.resizeSplit(
          at: path, ratio: ratio,
          in: tabID, in: worktreeID, in: projectID, in: spaceID
        )
      },
      setWorktreeGitViewerVisible: { worktreeID, visible in
        manager.setWorktreeGitViewerVisible(worktreeID: worktreeID, visible: visible)
      },
      snapshot: { manager.catalog },
      selectionChanges: { makeSelectionStream(manager: manager) },
      setWorktreeArchived: { worktreeID, archived in
        try manager.setWorktreeArchived(worktreeID: worktreeID, archived: archived)
      },
      setWorktreePinned: { worktreeID, isPinned in
        manager.setWorktreePinned(worktreeID: worktreeID, isPinned: isPinned)
      },
      setProjectExpanded: { projectID, isExpanded in
        manager.setProjectExpanded(projectID: projectID, isExpanded: isExpanded)
      },
      reconcileDiscoveredWorktrees: { projectID, spaceID in
        await reconcile(
          projectID: projectID,
          spaceID: spaceID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient
        )
      },
      createWorktreeWithGit: { projectID, spaceID, branch, _, path in
        try manager.createWorktree(
          in: projectID, in: spaceID,
          name: branch, path: path, branch: branch
        )
      },
      removeWorktreeWithGit: { worktreeID, projectID, spaceID in
        try await removeWorktreeWithGit(
          worktreeID: worktreeID,
          projectID: projectID,
          spaceID: spaceID,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient
        )
      },
      runningPaneCount: { worktreeID in
        manager.runningPaneCount(worktreeID: worktreeID)
      },
      setProjectLoadState: { projectID, spaceID, state in
        manager.setProjectLoadState(state, projectID: projectID, spaceID: spaceID)
      },
      reorderProjects: { spaceID, from, to in
        try manager.reorderProjects(in: spaceID, from: from, to: to)
      },
      isPathRegistered: { canonicalPath in
        manager.isPathRegistered(canonical: canonicalPath)
      },
      projectContaining: { canonicalPath in
        manager.project(containing: canonicalPath)
      },
      kind: { projectID in
        for space in manager.catalog.spaces {
          if let project = space.projects.first(where: { $0.id == projectID }) {
            return project.kind
          }
        }
        return nil
      },
      reorderSpaces: { source, destination in
        manager.reorderSpaces(fromOffsets: source, toOffset: destination)
      },
      addressOf: { paneID in
        guard let (spaceID, projectID, worktreeID, tabID) = manager.addressOf(paneID: paneID)
        else { return nil }
        return PaneAddress(
          spaceID: spaceID,
          projectID: projectID,
          worktreeID: worktreeID,
          tabID: tabID,
          paneID: paneID
        )
      },
      moveTab: { tabID, worktreeID, projectID, spaceID, offset in
        try manager.moveTab(
          tabID, in: worktreeID, in: projectID, in: spaceID, offset: offset
        )
      },
      equalizeTabSplits: { tabID, worktreeID, projectID, spaceID in
        try manager.equalizeTabSplits(tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      resizePane: { paneID, direction, amount in
        try manager.resizePane(paneID, direction: direction, amount: amount)
      },
      unzoomTab: { tabID, worktreeID, projectID, spaceID in
        try manager.unfocusPane(in: tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      runScript: { [weak settings] scriptID, projectID, worktreeID in
        try await runScript(
          scriptID: scriptID,
          projectID: projectID,
          worktreeID: worktreeID,
          manager: manager,
          settings: settings
        )
      },
      runWorktreeLifecycleScript: { [weak settings] phase, worktreeID, projectID in
        let snapshot = settings?.settings ?? .default
        return await manager.runWorktreeLifecycleScript(
          phase, for: worktreeID, in: projectID, settings: snapshot
        )
      },
      createWorktreeWithLifecycle: { [weak settings] projectID, spaceID, name, path, branch in
        let snapshot = settings?.settings ?? .default
        return try await manager.createWorktreeWithLifecycle(
          in: projectID, in: spaceID,
          name: name, path: path, branch: branch,
          settings: snapshot
        )
      },
      setWorktreeArchivedWithLifecycle: { [weak settings] worktreeID, projectID, archived in
        let snapshot = settings?.settings ?? .default
        return try await manager.setWorktreeArchivedWithLifecycle(
          worktreeID: worktreeID,
          archived: archived,
          in: projectID,
          settings: snapshot
        )
      },
      removeWorktreeWithLifecycle: { [weak settings] worktreeID, projectID, spaceID in
        let snapshot = settings?.settings ?? .default
        return try await manager.removeWorktreeWithLifecycle(
          worktreeID, from: projectID, in: spaceID, settings: snapshot
        )
      },
      reorderWorktrees: { projectID, spaceID, segment, from, to in
        try manager.reorderWorktrees(
          in: projectID, inSpace: spaceID,
          segment: segment, from: from, to: to
        )
      }
    )
  }

  /// Looks up the script + worktree, opens a fresh tab named after the script,
  /// and types the script's command into the new pane. Throws when the script
  /// id was deleted between click and effect or the worktree is gone.
  /// Project envVars injection lands in M8 (PaneSurface env hook); this
  /// implementation already routes through `resolvedEnv` so the value is
  /// computed once the runtime path consumes it.
  @MainActor
  private static func runScript(
    scriptID: UUID,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    manager: HierarchyManager,
    settings: SettingsStore?
  ) async throws {
    let snapshot = settings?.settings ?? .default
    guard let project = snapshot.projects[projectID],
      let script = project.scripts.first(where: { $0.id == scriptID })
    else {
      throw RunScriptError.unknownScript(scriptID)
    }
    var foundSpaceID: SpaceID?
    var foundWorktreePath: String?
    outer: for space in manager.catalog.spaces {
      for project in space.projects where project.id == projectID {
        for worktree in project.worktrees where worktree.id == worktreeID {
          foundSpaceID = space.id
          foundWorktreePath = worktree.path
          break outer
        }
      }
    }
    guard let spaceID = foundSpaceID, let cwd = foundWorktreePath else {
      throw RunScriptError.missingWorktree(worktreeID)
    }
    // M8: forward the resolved env into the spawn path so the new pane's
    // pty inherits Project-defined envVars (project keys win over process
    // env). PaneSurface threads this into ghostty_surface_config_s.env_vars.
    let env = HierarchyManager.resolvedEnv(for: projectID, in: snapshot)

    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, in: spaceID,
      name: script.displayName
    )
    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID, in: spaceID,
      workingDirectory: cwd,
      initialCommand: script.command,
      env: env
    )
  }

  /// Factored out so the closure body stays one-line-callable. Resolves
  /// the Project's git root, lists on-disk worktrees via `wt ls --json`,
  /// and hands the result to `manager.reconcileDiscoveredWorktrees`.
  /// Each entry's `path` is passed through `HierarchyManager.canonicalPath`
  /// so `wt ls`'s `/var/...` output matches the symlink-resolved form
  /// T-PROJECT stores for `Project.rootPath` — without this normalization
  /// the main checkout would duplicate on every reconcile under `/tmp`
  /// and `/var`. Swallows and logs `GitWorktreeError` — this path is
  /// idempotent and must never crash a reconcile (see design doc
  /// §Discovery / Reconcile).
  @MainActor
  private static func reconcile(
    projectID: ProjectID,
    spaceID: SpaceID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient
  ) async {
    guard let space = manager.catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let gitRoot = project.gitRoot
    else { return }
    do {
      let entries = try await gitWorktreeClient.lsWorktrees(
        URL(fileURLWithPath: gitRoot)
      )
      let mapped = entries.map { entry -> (path: String, branch: String?) in
        let branch = entry.branch.isEmpty ? nil : entry.branch
        return (path: HierarchyManager.canonicalPath(entry.path), branch: branch)
      }
      _ = manager.reconcileDiscoveredWorktrees(
        projectID: projectID,
        inSpace: spaceID,
        entries: mapped
      )
    } catch {
      // Log under com.touch-code.hierarchy/reconcile and swallow —
      // never throw, never crash a reconcile (see design doc
      // §Discovery / Reconcile). `projectID` is printed as .public
      // because it's a UUID opaque to users; the error description
      // is `.private(mask: .hash)` because `GitWorktreeError
      // .commandFailed` carries raw git stderr which can embed
      // local absolute paths. Issue #24 (d) + PR #31 review F2.
      reconcileLogger.error(
        "reconcileDiscoveredWorktrees failed: project=\(projectID.raw.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
      )
    }
  }

  /// Factored out of the `removeWorktreeWithGit` closure so the
  /// control flow stays readable. Tears down all surfaces first (the
  /// relocate-then-prune step about to run will move the worktree's
  /// working directory out from under any open terminals, so panes
  /// holding the cwd as a live file descriptor must be closed
  /// beforehand), then runs git, then drops the catalog row.
  /// Re-throws `GitWorktreeError` for the caller to surface.
  @MainActor
  private static func removeWorktreeWithGit(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID,
    manager: HierarchyManager,
    gitWorktreeClient: GitWorktreeClient
  ) async throws {
    guard let space = manager.catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let gitRoot = project.gitRoot
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    manager.tearDownWorktreeSurfaces(worktreeID: worktreeID)
    try await gitWorktreeClient.removeWorktree(
      URL(fileURLWithPath: gitRoot),
      URL(fileURLWithPath: worktree.path)
    )
    try manager.removeWorktree(worktreeID, from: projectID, in: spaceID)
  }

  /// AsyncStream backed by Swift Observation — samples `manager.catalog`'s
  /// selection chain and yields a new `HierarchySelection` whenever any of
  /// the three IDs changes. Closes the re-arm race window by sampling
  /// `currentSelection` BEFORE arming the next `withObservationTracking`
  /// block: any mutation that landed between the prior yield and the next
  /// arm is caught on the pre-arm compare; `withObservationTracking` then
  /// only waits for mutations that land after the new snapshot.
  @MainActor
  private static func makeSelectionStream(manager: HierarchyManager) -> AsyncStream<HierarchySelection> {
    AsyncStream { continuation in
      let task = Task { @MainActor in
        var last = currentSelection(for: manager)
        continuation.yield(last)
        while !Task.isCancelled {
          // Sample FIRST — catches any mutation that landed during the
          // gap between yield and re-arm.
          let preArm = currentSelection(for: manager)
          if preArm != last {
            continuation.yield(preArm)
            last = preArm
          }
          await withCheckedContinuation { (observationContinuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
              _ = currentSelection(for: manager)
            } onChange: {
              observationContinuation.resume()
            }
          }
          let current = currentSelection(for: manager)
          if current != last {
            continuation.yield(current)
            last = current
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  @MainActor
  private static func currentSelection(for manager: HierarchyManager) -> HierarchySelection {
    let catalog = manager.catalog
    let spaceID = catalog.selectedSpaceID
    let space = spaceID.flatMap { id in catalog.spaces.first(where: { $0.id == id }) }
    let projectID = space?.selectedProjectID
    let project = projectID.flatMap { id in space?.projects.first(where: { $0.id == id }) }
    let worktreeID = project?.selectedWorktreeID
    return HierarchySelection(
      spaceID: spaceID,
      projectID: projectID,
      worktreeID: worktreeID
    )
  }
}

// MARK: - DependencyKey

extension HierarchyClient: DependencyKey {
  static let liveValue: HierarchyClient = HierarchyClient(
    createSpace: { _ in
      fatalError("HierarchyClient.liveValue not configured; wire via .withDependencies at app startup")
    },
    renameSpace: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeSpace: { _ in fatalError("HierarchyClient.liveValue not configured") },
    addProject: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeProject: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    renameProject: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktree: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktree: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setSpaceLastActiveWorktree: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectSpace: { _ in fatalError("HierarchyClient.liveValue not configured") },
    selectProject: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectWorktree: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    renameTab: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderTabs: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeOtherTabs: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeTabsToRight: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closeAllTabs: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    selectAdjacentTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    tabIsDirty: { _ in false },
    lastFocusedPane: { _ in nil },
    markPaneRunning: { _ in },
    markPaneIdle: { _ in },
    openPane: { _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    splitPane: { _, _, _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closePane: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusPane: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusSurfaceView: { _ in fatalError("HierarchyClient.liveValue not configured") },
    resizeSplit: { _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreeGitViewerVisible: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    snapshot: { fatalError("HierarchyClient.liveValue not configured") },
    selectionChanges: { AsyncStream { $0.finish() } },
    setWorktreeArchived: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreePinned: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectExpanded: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reconcileDiscoveredWorktrees: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktreeWithGit: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktreeWithGit: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runningPaneCount: { _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectLoadState: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderProjects: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    isPathRegistered: { _ in fatalError("HierarchyClient.liveValue not configured") },
    projectContaining: { _ in fatalError("HierarchyClient.liveValue not configured") },
    kind: { _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderSpaces: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    addressOf: { _ in fatalError("HierarchyClient.liveValue not configured") },
    moveTab: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    equalizeTabSplits: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    resizePane: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    unzoomTab: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runScript: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runWorktreeLifecycleScript: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    createWorktreeWithLifecycle: { _, _, _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    setWorktreeArchivedWithLifecycle: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    removeWorktreeWithLifecycle: { _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    },
    reorderWorktrees: { _, _, _, _, _ in
      fatalError("HierarchyClient.liveValue not configured")
    }
  )

  static let testValue: HierarchyClient = HierarchyClient(
    createSpace: unimplemented("HierarchyClient.createSpace", placeholder: SpaceID()),
    renameSpace: unimplemented("HierarchyClient.renameSpace"),
    removeSpace: unimplemented("HierarchyClient.removeSpace"),
    addProject: unimplemented("HierarchyClient.addProject", placeholder: ProjectID()),
    removeProject: unimplemented("HierarchyClient.removeProject"),
    renameProject: unimplemented("HierarchyClient.renameProject"),
    createWorktree: unimplemented("HierarchyClient.createWorktree", placeholder: WorktreeID()),
    removeWorktree: unimplemented("HierarchyClient.removeWorktree"),
    setSpaceLastActiveWorktree: unimplemented("HierarchyClient.setSpaceLastActiveWorktree"),
    selectSpace: unimplemented("HierarchyClient.selectSpace"),
    selectProject: unimplemented("HierarchyClient.selectProject"),
    selectWorktree: unimplemented("HierarchyClient.selectWorktree"),
    createTab: unimplemented("HierarchyClient.createTab", placeholder: TabID()),
    closeTab: unimplemented("HierarchyClient.closeTab"),
    selectTab: unimplemented("HierarchyClient.selectTab"),
    renameTab: unimplemented("HierarchyClient.renameTab"),
    reorderTabs: unimplemented("HierarchyClient.reorderTabs"),
    closeOtherTabs: unimplemented("HierarchyClient.closeOtherTabs"),
    closeTabsToRight: unimplemented("HierarchyClient.closeTabsToRight"),
    closeAllTabs: unimplemented("HierarchyClient.closeAllTabs"),
    selectAdjacentTab: unimplemented("HierarchyClient.selectAdjacentTab", placeholder: nil),
    tabIsDirty: unimplemented("HierarchyClient.tabIsDirty", placeholder: false),
    lastFocusedPane: unimplemented("HierarchyClient.lastFocusedPane", placeholder: nil),
    markPaneRunning: unimplemented("HierarchyClient.markPaneRunning"),
    markPaneIdle: unimplemented("HierarchyClient.markPaneIdle"),
    openPane: unimplemented("HierarchyClient.openPane", placeholder: PaneID()),
    splitPane: unimplemented("HierarchyClient.splitPane", placeholder: PaneID()),
    closePane: unimplemented("HierarchyClient.closePane"),
    focusPane: unimplemented("HierarchyClient.focusPane"),
    focusSurfaceView: unimplemented("HierarchyClient.focusSurfaceView"),
    resizeSplit: unimplemented("HierarchyClient.resizeSplit"),
    setWorktreeGitViewerVisible: unimplemented("HierarchyClient.setWorktreeGitViewerVisible"),
    snapshot: unimplemented(
      "HierarchyClient.snapshot",
      placeholder: Catalog(windows: [], spaces: [], selectedSpaceID: nil)
    ),
    selectionChanges: unimplemented(
      "HierarchyClient.selectionChanges",
      placeholder: AsyncStream { $0.finish() }
    ),
    setWorktreeArchived: unimplemented("HierarchyClient.setWorktreeArchived"),
    setWorktreePinned: unimplemented("HierarchyClient.setWorktreePinned"),
    setProjectExpanded: unimplemented("HierarchyClient.setProjectExpanded"),
    reconcileDiscoveredWorktrees: unimplemented("HierarchyClient.reconcileDiscoveredWorktrees"),
    createWorktreeWithGit: unimplemented(
      "HierarchyClient.createWorktreeWithGit", placeholder: WorktreeID()
    ),
    removeWorktreeWithGit: unimplemented("HierarchyClient.removeWorktreeWithGit"),
    runningPaneCount: unimplemented("HierarchyClient.runningPaneCount", placeholder: 0),
    setProjectLoadState: unimplemented("HierarchyClient.setProjectLoadState"),
    reorderProjects: unimplemented("HierarchyClient.reorderProjects"),
    isPathRegistered: unimplemented("HierarchyClient.isPathRegistered", placeholder: nil),
    projectContaining: unimplemented("HierarchyClient.projectContaining", placeholder: nil),
    kind: unimplemented("HierarchyClient.kind", placeholder: nil),
    reorderSpaces: unimplemented("HierarchyClient.reorderSpaces"),
    addressOf: unimplemented("HierarchyClient.addressOf", placeholder: nil),
    moveTab: unimplemented("HierarchyClient.moveTab"),
    equalizeTabSplits: unimplemented("HierarchyClient.equalizeTabSplits"),
    resizePane: unimplemented("HierarchyClient.resizePane"),
    unzoomTab: unimplemented("HierarchyClient.unzoomTab"),
    runScript: unimplemented("HierarchyClient.runScript"),
    runWorktreeLifecycleScript: unimplemented(
      "HierarchyClient.runWorktreeLifecycleScript",
      placeholder: .skipped
    ),
    createWorktreeWithLifecycle: unimplemented(
      "HierarchyClient.createWorktreeWithLifecycle",
      placeholder: (WorktreeID(), .skipped)
    ),
    setWorktreeArchivedWithLifecycle: unimplemented(
      "HierarchyClient.setWorktreeArchivedWithLifecycle",
      placeholder: .skipped
    ),
    removeWorktreeWithLifecycle: unimplemented(
      "HierarchyClient.removeWorktreeWithLifecycle",
      placeholder: .skipped
    ),
    reorderWorktrees: unimplemented("HierarchyClient.reorderWorktrees")
  )
}

extension DependencyValues {
  var hierarchyClient: HierarchyClient {
    get { self[HierarchyClient.self] }
    set { self[HierarchyClient.self] = newValue }
  }
}
