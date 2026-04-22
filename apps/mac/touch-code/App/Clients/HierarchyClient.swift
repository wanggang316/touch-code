import ComposableArchitecture
import Foundation
import Observation
import OSLog
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

  var addProject: @MainActor @Sendable (
    _ spaceID: SpaceID, _ name: String, _ rootPath: String, _ gitRoot: String?
  ) throws -> ProjectID
  var removeProject: @MainActor @Sendable (_ projectID: ProjectID, _ inSpace: SpaceID) throws -> Void
  var renameProject: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String
  ) throws -> Void

  var createWorktree: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String, _ path: String, _ branch: String?
  ) throws -> WorktreeID
  var removeWorktree: @MainActor @Sendable (
    _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void

  /// Records which Worktree to restore when the window re-activates this Space.
  /// `nil` clears. Missing space / unchanged value is a silent no-op — matches
  /// `HierarchyManager.setSpaceLastActiveWorktree` contract.
  var setSpaceLastActiveWorktree: @MainActor @Sendable (
    _ spaceID: SpaceID, _ worktreeID: WorktreeID?
  ) -> Void

  var selectSpace: @MainActor @Sendable (_ id: SpaceID?) -> Void
  var selectProject: @MainActor @Sendable (_ id: ProjectID?, _ inSpace: SpaceID) throws -> Void
  var selectWorktree: @MainActor @Sendable (
    _ id: WorktreeID?, _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void

  var createTab: @MainActor @Sendable (
    _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID, _ name: String?
  ) throws -> TabID
  var closeTab: @MainActor @Sendable (
    _ id: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void
  var selectTab: @MainActor @Sendable (
    _ id: TabID?, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void

  var openPanel: @MainActor @Sendable (
    _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
    _ workingDirectory: String, _ initialCommand: String?
  ) throws -> PanelID
  var splitPanel: @MainActor @Sendable (
    _ panelID: PanelID, _ direction: SplitTree<PanelID>.NewDirection,
    _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
    _ workingDirectory: String, _ initialCommand: String?
  ) throws -> PanelID
  var closePanel: @MainActor @Sendable (
    _ panelID: PanelID, _ tabID: TabID, _ inWorktree: WorktreeID,
    _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void
  var focusPanel: @MainActor @Sendable (
    _ panelID: PanelID, _ tabID: TabID, _ inWorktree: WorktreeID,
    _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void
  var resizeSplit: @MainActor @Sendable (
    _ path: SplitTree<PanelID>.Path, _ ratio: Double,
    _ tabID: TabID, _ inWorktree: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void

  /// Sets the per-Project default editor override. `nil` unsets the override so resolution
  /// falls back to the global default (via `SettingsStore`). Added in 0005 M6a for C8's
  /// Worktree-header "Open in ▾" + Settings override UI.
  var setDefaultEditor: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID, _ editorID: EditorID?
  ) throws -> Void

  /// Flips `Worktree.gitViewerVisible` for the given Worktree. Silent no-op on
  /// unknown `worktreeID`; persists through the standard debounced
  /// `store.scheduleSave(catalog)` pipeline (T0 §D5). Consumed by the T2
  /// Header Git Viewer toggle and by T3's overlay presentation binding.
  var setWorktreeGitViewerVisible: @MainActor @Sendable (
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
  var setWorktreeArchived: @MainActor @Sendable (
    _ worktreeID: WorktreeID, _ archived: Bool
  ) throws -> Void

  /// Reads the Project's git root, calls `GitWorktreeClient.lsWorktrees`
  /// off the main actor, and merges on-disk worktrees into the catalog.
  /// Append-only — never removes catalog rows. Swallows errors. Consumed
  /// by `ProjectReconciler` on feat/project-mgmt.
  var reconcileDiscoveredWorktrees: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID
  ) async -> Void

  /// Catalog-append step for Create Worktree.
  var createWorktreeWithGit: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID,
    _ branch: String, _ directoryName: String, _ path: String
  ) throws -> WorktreeID

  /// End-to-end Remove Worktree. `GitWorktreeError.uncommittedChanges` is
  /// re-thrown so the sidebar can surface the specific files.
  var removeWorktreeWithGit: @MainActor @Sendable (
    _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID,
    _ force: Bool
  ) async throws -> Void

  /// Forwards `HierarchyManager.runningPanelCount`.
  var runningPanelCount: @MainActor @Sendable (_ worktreeID: WorktreeID) -> Int

  // MARK: - Project Management (pm) — added on feat/project-mgmt.

  /// Transient Project health signal. Written by `ProjectReconciler` only.
  var setProjectLoadState: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID, _ state: ProjectLoadState
  ) -> Void

  /// Reorder Projects inside a Space. Mirrors `ForEach.onMove`'s signature.
  var reorderProjects: @MainActor @Sendable (
    _ inSpace: SpaceID, _ from: IndexSet, _ to: Int
  ) throws -> Void

  /// Per-Project worktrees-directory override. Empty/whitespace clears.
  var setProjectWorktreesDirectory: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID, _ path: String?
  ) throws -> Void

  /// Duplicate-add guard. Caller canonicalizes before querying.
  var isPathRegistered: @MainActor @Sendable (_ canonicalPath: String) -> (SpaceID, ProjectID)?

  // MARK: - Space Management additions (feat/space-mgmt)

  /// Reorder Spaces using the IndexSet (source) and destination offset from
  /// SwiftUI's `.onMove(perform:)`. Silent no-op on empty IndexSet.
  var reorderSpaces: @MainActor @Sendable (_ source: IndexSet, _ destination: Int) -> Void
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
      openPanel: { tabID, worktreeID, projectID, spaceID, cwd, initial in
        try manager.openPanel(
          in: tabID, in: worktreeID, in: projectID, in: spaceID,
          workingDirectory: cwd, initialCommand: initial
        )
      },
      splitPanel: { panelID, direction, tabID, worktreeID, projectID, spaceID, cwd, initial in
        try manager.splitPanel(
          panelID, direction: direction,
          in: tabID, in: worktreeID, in: projectID, in: spaceID,
          workingDirectory: cwd, initialCommand: initial
        )
      },
      closePanel: { panelID, tabID, worktreeID, projectID, spaceID in
        try manager.closePanel(panelID, in: tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      focusPanel: { panelID, tabID, worktreeID, projectID, spaceID in
        try manager.focusPanel(panelID, in: tabID, in: worktreeID, in: projectID, in: spaceID)
      },
      resizeSplit: { path, ratio, tabID, worktreeID, projectID, spaceID in
        try manager.resizeSplit(
          at: path, ratio: ratio,
          in: tabID, in: worktreeID, in: projectID, in: spaceID
        )
      },
      setDefaultEditor: { projectID, spaceID, editorID in
        try manager.setDefaultEditor(editorID, for: projectID, in: spaceID)
      },
      setWorktreeGitViewerVisible: { worktreeID, visible in
        manager.setWorktreeGitViewerVisible(worktreeID: worktreeID, visible: visible)
      },
      snapshot: { manager.catalog },
      selectionChanges: { makeSelectionStream(manager: manager) },
      setWorktreeArchived: { worktreeID, archived in
        try manager.setWorktreeArchived(worktreeID: worktreeID, archived: archived)
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
      removeWorktreeWithGit: { worktreeID, projectID, spaceID, force in
        try await removeWorktreeWithGit(
          worktreeID: worktreeID,
          projectID: projectID,
          spaceID: spaceID,
          force: force,
          manager: manager,
          gitWorktreeClient: gitWorktreeClient
        )
      },
      runningPanelCount: { worktreeID in
        manager.runningPanelCount(worktreeID: worktreeID)
      },
      setProjectLoadState: { projectID, spaceID, state in
        manager.setProjectLoadState(state, projectID: projectID, spaceID: spaceID)
      },
      reorderProjects: { spaceID, from, to in
        try manager.reorderProjects(in: spaceID, from: from, to: to)
      },
      setProjectWorktreesDirectory: { projectID, spaceID, path in
        try manager.setProjectWorktreesDirectory(path, projectID: projectID, spaceID: spaceID)
      },
      isPathRegistered: { canonicalPath in
        manager.isPathRegistered(canonical: canonicalPath)
      },
      reorderSpaces: { source, destination in
        manager.reorderSpaces(fromOffsets: source, toOffset: destination)
      }
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
      // likewise carries no PII. Issue #24 (d).
      reconcileLogger.error(
        "reconcileDiscoveredWorktrees failed: project=\(projectID.raw.uuidString, privacy: .public) \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Factored out of the `removeWorktreeWithGit` closure so the
  /// control flow stays readable. On force, tears down surfaces first
  /// (releases file handles), then runs git, then drops the catalog
  /// row. On safe, skips the pre-teardown so uncommitted-changes
  /// recovery does not kill a live terminal. Re-throws
  /// `GitWorktreeError` for the caller to surface.
  @MainActor
  private static func removeWorktreeWithGit(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID,
    force: Bool,
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
    if force {
      manager.tearDownWorktreeSurfaces(worktreeID: worktreeID)
    }
    try await gitWorktreeClient.removeWorktree(
      URL(fileURLWithPath: gitRoot),
      URL(fileURLWithPath: worktree.path),
      force
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
    createSpace: { _ in fatalError("HierarchyClient.liveValue not configured; wire via .withDependencies at app startup") },
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
    openPanel: { _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    splitPanel: { _, _, _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    closePanel: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    focusPanel: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    resizeSplit: { _, _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setDefaultEditor: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setWorktreeGitViewerVisible: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    snapshot: { fatalError("HierarchyClient.liveValue not configured") },
    selectionChanges: { AsyncStream { $0.finish() } },
    setWorktreeArchived: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reconcileDiscoveredWorktrees: { _, _ in fatalError("HierarchyClient.liveValue not configured") },
    createWorktreeWithGit: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktreeWithGit: { _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    runningPanelCount: { _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectLoadState: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderProjects: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    setProjectWorktreesDirectory: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    isPathRegistered: { _ in fatalError("HierarchyClient.liveValue not configured") },
    reorderSpaces: { _, _ in fatalError("HierarchyClient.liveValue not configured") }
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
    openPanel: unimplemented("HierarchyClient.openPanel", placeholder: PanelID()),
    splitPanel: unimplemented("HierarchyClient.splitPanel", placeholder: PanelID()),
    closePanel: unimplemented("HierarchyClient.closePanel"),
    focusPanel: unimplemented("HierarchyClient.focusPanel"),
    resizeSplit: unimplemented("HierarchyClient.resizeSplit"),
    setDefaultEditor: unimplemented("HierarchyClient.setDefaultEditor"),
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
    reconcileDiscoveredWorktrees: unimplemented("HierarchyClient.reconcileDiscoveredWorktrees"),
    createWorktreeWithGit: unimplemented(
      "HierarchyClient.createWorktreeWithGit", placeholder: WorktreeID()
    ),
    removeWorktreeWithGit: unimplemented("HierarchyClient.removeWorktreeWithGit"),
    runningPanelCount: unimplemented("HierarchyClient.runningPanelCount", placeholder: 0),
    setProjectLoadState: unimplemented("HierarchyClient.setProjectLoadState"),
    reorderProjects: unimplemented("HierarchyClient.reorderProjects"),
    setProjectWorktreesDirectory: unimplemented("HierarchyClient.setProjectWorktreesDirectory"),
    isPathRegistered: unimplemented("HierarchyClient.isPathRegistered", placeholder: nil),
    reorderSpaces: unimplemented("HierarchyClient.reorderSpaces")
  )
}

extension DependencyValues {
  var hierarchyClient: HierarchyClient {
    get { self[HierarchyClient.self] }
    set { self[HierarchyClient.self] = newValue }
  }
}
