import ComposableArchitecture
import Foundation
import Observation
import TouchCodeCore

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

  var createWorktree: @MainActor @Sendable (
    _ projectID: ProjectID, _ inSpace: SpaceID, _ name: String, _ path: String, _ branch: String?
  ) throws -> WorktreeID
  var removeWorktree: @MainActor @Sendable (
    _ worktreeID: WorktreeID, _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void

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

  var snapshot: @MainActor @Sendable () -> Catalog

  /// Emits whenever the selection chain `(spaceID, projectID, worktreeID)`
  /// changes in the catalog. Deduped against the previous snapshot. Consumers
  /// (C6 inbox, C7 git-viewer, M4 detail-column swap) subscribe without
  /// needing a reference to the `@Observable` `HierarchyManager`. The stream
  /// finishes only when the engine shuts down.
  var selectionChanges: @MainActor @Sendable () -> AsyncStream<HierarchySelection>
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
  static func live(manager: HierarchyManager) -> HierarchyClient {
    HierarchyClient(
      createSpace: { manager.createSpace(name: $0) },
      renameSpace: { try manager.renameSpace($0, name: $1) },
      removeSpace: { try manager.removeSpace($0) },
      addProject: { try manager.addProject(to: $0, name: $1, rootPath: $2, gitRoot: $3) },
      removeProject: { try manager.removeProject($0, from: $1) },
      createWorktree: { projectID, spaceID, name, path, branch in
        try manager.createWorktree(in: projectID, in: spaceID, name: name, path: path, branch: branch)
      },
      removeWorktree: { worktreeID, projectID, spaceID in
        try manager.removeWorktree(worktreeID, from: projectID, in: spaceID)
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
      snapshot: { manager.catalog },
      selectionChanges: { makeSelectionStream(manager: manager) }
    )
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
    createWorktree: { _, _, _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
    removeWorktree: { _, _, _ in fatalError("HierarchyClient.liveValue not configured") },
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
    snapshot: { fatalError("HierarchyClient.liveValue not configured") },
    selectionChanges: { AsyncStream { $0.finish() } }
  )

  static let testValue: HierarchyClient = HierarchyClient(
    createSpace: unimplemented("HierarchyClient.createSpace", placeholder: SpaceID()),
    renameSpace: unimplemented("HierarchyClient.renameSpace"),
    removeSpace: unimplemented("HierarchyClient.removeSpace"),
    addProject: unimplemented("HierarchyClient.addProject", placeholder: ProjectID()),
    removeProject: unimplemented("HierarchyClient.removeProject"),
    createWorktree: unimplemented("HierarchyClient.createWorktree", placeholder: WorktreeID()),
    removeWorktree: unimplemented("HierarchyClient.removeWorktree"),
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
    snapshot: unimplemented(
      "HierarchyClient.snapshot",
      placeholder: Catalog(windows: [], spaces: [], selectedSpaceID: nil)
    ),
    selectionChanges: unimplemented(
      "HierarchyClient.selectionChanges",
      placeholder: AsyncStream { $0.finish() }
    )
  )
}

extension DependencyValues {
  var hierarchyClient: HierarchyClient {
    get { self[HierarchyClient.self] }
    set { self[HierarchyClient.self] = newValue }
  }
}
