import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Returns the smallest-index unused "Untitled Space [N]" name given the
/// current list of Spaces. Treats bare "Untitled Space" as the N=1 slot;
/// the first new Space gets bare, the second gets "Untitled Space 2", and
/// so on, filling holes before extending the tail.
///
/// Pure. No disk I/O, no MainActor. Exposed to tests via `@testable import`.
/// File-scope (not method on the reducer) so the reducer stays focused on
/// action→effect mapping and the test target can call it without touching
/// TCA machinery.
func nextUntitledSpaceName(in spaces: [Space]) -> String {
  let bare = "Untitled Space"
  var occupied: Set<Int> = []
  for space in spaces {
    if space.name == bare {
      occupied.insert(1)
      continue
    }
    guard space.name.hasPrefix(bare + " ") else { continue }
    let suffix = space.name.dropFirst(bare.count + 1)
    // Reject leading zeros, signs, whitespace — only a clean positive integer counts.
    guard !suffix.isEmpty,
      suffix.allSatisfy(\.isNumber),
      suffix.first != "0",
      let n = Int(suffix),
      n > 0
    else { continue }
    occupied.insert(n)
  }
  var candidate = 1
  while occupied.contains(candidate) { candidate += 1 }
  return candidate == 1 ? bare : "\(bare) \(candidate)"
}

// MARK: - Transient sheet / dialog payloads

/// Stub-sheet payload for Project-header "+" (add Worktree). Retained
/// for the brief window between `.projectAddWorktreeTapped` firing and
/// the real `CreateWorktreeFeature.State` being seeded in the next
/// reducer step. Carries just the parent IDs needed to resolve the
/// Project from `HierarchyManager.catalog` when building the child state.
struct AddWorktreeSheet: Equatable {
  var projectID: ProjectID
  var spaceID: SpaceID
}

/// Worktree-remove confirmation payload. Non-nil → `.confirmationDialog` visible.
/// `displayName` is captured at tap-time so the dialog title shows the correct
/// name even if the catalog mutates before the user confirms.
struct PendingWorktreeRemoval: Equatable {
  var worktreeID: WorktreeID
  var projectID: ProjectID
  var spaceID: SpaceID
  var displayName: String
}

/// Project-remove confirmation payload. Symmetric to `PendingWorktreeRemoval`
/// — Remove Project transitively removes every child Worktree, killing their
/// terminal surfaces, so we gate it with the same confirm pattern.
struct PendingProjectRemoval: Equatable {
  var projectID: ProjectID
  var spaceID: SpaceID
  var displayName: String
}

/// Sidebar reducer for the Space → Project → Worktree hierarchy. Owns
/// local view state (expansion sets, popover visibility, sheet payloads,
/// confirmation dialogs) and the Space-switch choreography. Structural
/// catalog data is NOT in state — `HierarchySidebarView` reads
/// `HierarchyManager.catalog` from the SwiftUI environment directly,
/// matching the state-ownership trade-off recorded in the T0 design doc.
///
/// Side effects for Reveal-in-Finder and Open-in-default-editor route
/// through `.delegate` actions so `RootFeature` composes them with the
/// `EditorFeature` open path and the `FinderClient` dependency. Keeps
/// this reducer free of AppKit and from duplicating editor-resolution
/// logic.
@Reducer
struct HierarchySidebarFeature {
  @ObservableState
  struct State: Equatable {
    /// Retained from pre-T1. The outer Space-level `DisclosureGroup` was
    /// removed in T1 (the tree now renders the active Space's projects
    /// flat), but this set and its prune path stay so existing tests keep
    /// passing and a future iteration can reintroduce space-level grouping
    /// without re-plumbing state.
    var expandedSpaceIDs: Set<SpaceID> = []
    // Project disclosure state used to live here as `expandedProjectIDs`. It
    // now persists on `Project.isExpanded` so the open / closed choice
    // survives restart — the view reads `project.isExpanded` directly from
    // the catalog, mirroring how `Worktree.isPinned` is consumed.

    var isSpacePopoverPresented: Bool = false

    /// Add Project sheet state. Presence-driven: non-nil means the sheet is
    /// visible. `.addProject` actions are scoped into `AddProjectFeature`.
    /// `@Presents` gives us `.sheet(item:)`-compatible scoping and wires
    /// dismiss semantics (`PresentationAction.dismiss`) automatically.
    @Presents var addProject: AddProjectFeature.State?
    /// Project Options sheet state. Subsumes what used to be the separate
    /// Rename Project sheet; `⋯` menu launches this with a Project-snapshot.
    @Presents var projectOptions: ProjectOptionsFeature.State?
    var addWorktreeSheet: AddWorktreeSheet?
    var createWorktreeSheet: CreateWorktreeFeature.State?
    var archivedWorktreesSheet: ArchivedWorktreesFeature.State?
    var pendingWorktreeRemoval: PendingWorktreeRemoval?
    var pendingProjectRemoval: PendingProjectRemoval?
    /// Pending force-remove follow-up on the main sidebar row (outside
    /// the Archived sheet). Triggered when safe-remove fails with
    /// `.uncommittedChanges`. Distinct from
    /// `ArchivedWorktreesFeature.pendingForceRemove`, which governs the
    /// in-sheet variant.
    var pendingForceRemove: PendingForceRemoval?
    /// Second-stage confirmation for force-remove when the Worktree
    /// has live terminal surfaces. Non-nil → "This will terminate N
    /// running processes" alert visible.
    var pendingRunningTerminalWarning: PendingRunningTerminalWarning?
    /// Session-scoped "seen it" flag for the first-archive explainer.
    /// Lives on this reducer (sidebar is the sole archive entry point
    /// for the main list; Archived sheet handles its own flow).
    var hasShownArchiveExplainer: Bool = false
    /// Pending archive awaiting the first-archive explainer dialog.
    var pendingArchiveExplainer: PendingArchiveExplainer?
    /// Transient toast after Prune completes.
    var pruneToast: String?
  }

  /// Payload for the first-archive explainer dialog. Carries the
  /// originating `(spaceID, projectID, name)` so the post-confirm path
  /// can run the archive-script wrapper without re-walking the catalog.
  struct PendingArchiveExplainer: Equatable {
    var worktreeID: WorktreeID
    var projectID: ProjectID
    var spaceID: SpaceID
    var name: String
  }

  /// Payload for the safe-remove → force-remove escalation on the main
  /// sidebar row. Captured at `.uncommittedChanges` time so the alert
  /// message can enumerate the offending files.
  struct PendingForceRemoval: Equatable {
    var worktreeID: WorktreeID
    var projectID: ProjectID
    var spaceID: SpaceID
    var displayName: String
    var uncommittedFiles: [String]
  }

  /// Second stage of the force-remove ladder — asks for explicit
  /// consent before the runtime hard-kills the Worktree's terminals.
  struct PendingRunningTerminalWarning: Equatable {
    var worktreeID: WorktreeID
    var projectID: ProjectID
    var spaceID: SpaceID
    var displayName: String
    var count: Int
  }

  enum Action: Equatable {
    // Row taps
    case spaceRowTapped(SpaceID)
    case projectRowTapped(ProjectID, inSpace: SpaceID)
    case worktreeRowTapped(WorktreeID, inProject: ProjectID, inSpace: SpaceID)

    // Expansion
    case toggleSpaceExpansion(SpaceID)
    case toggleProjectExpansion(ProjectID)
    /// Invoked by the parent reducer when the catalog mutation stream fires
    /// — prunes stale Space IDs from `expandedSpaceIDs`. Project expansion
    /// lives on `Project.isExpanded` and is pruned automatically when the
    /// Project itself disappears from the catalog, so it is not threaded here.
    case pruneExpansionSets(currentSpaceIDs: Set<SpaceID>)

    // Toolbar
    case toolbarAddProjectTapped
    /// Placeholder for future sidebar-toolbar "⋯" menu items. No-op today.
    case toolbarMenuTapped

    // Reorder Projects within a Space (ForEach.onMove forwarder).
    case reorderProjects(from: IndexSet, to: Int, inSpace: SpaceID)

    /// Fired from `FailedProjectRow.Retry` (or the context menu). Delegates
    /// to `RootFeature` which calls `ProjectReconciler.reconcile` — same path
    /// used after Add Project.
    case retryProjectTapped(projectID: ProjectID, inSpace: SpaceID)

    // Project section hover chrome
    case projectAddWorktreeTapped(projectID: ProjectID, inSpace: SpaceID)
    /// Open the Project Options sheet for the given row. Replaces the
    /// standalone Rename Project sheet actions (P-Q2 = a).
    case projectOptionsTapped(projectID: ProjectID, inSpace: SpaceID)
    case projectRemoveTapped(projectID: ProjectID, inSpace: SpaceID, name: String)
    case projectRemoveConfirmed
    case projectRemoveCancelled

    // Worktree row context menu
    case worktreeRemoveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      inSpace: SpaceID,
      name: String
    )
    case worktreeRemoveConfirmed
    case worktreeRemoveCancelled

    // Safe-remove → force-remove ladder (feat/worktree-mgmt)
    case worktreeRemoveFailed(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      inSpace: SpaceID,
      name: String,
      error: GitWorktreeError
    )
    case worktreeForceRemoveConfirmed
    case worktreeForceRemoveCancelled
    case worktreeRunningTerminalWarningConfirmed
    case worktreeRunningTerminalWarningCancelled

    // Archive actions on the main worktree row.
    case worktreeArchiveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      inSpace: SpaceID,
      name: String
    )
    case worktreeArchiveConfirmed
    case worktreeArchiveCancelled
    case worktreeUnarchiveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      inSpace: SpaceID
    )
    /// Right-click menu toggle. Flips the Worktree's `isPinned` flag via `HierarchyClient`.
    /// The `current` parameter lets the reducer emit the opposite value without reading
    /// catalog state.
    case worktreePinToggleTapped(worktreeID: WorktreeID, current: Bool)

    // Project ⋯ menu: Archived + Prune.
    case projectShowArchivedTapped(projectID: ProjectID, inSpace: SpaceID)
    case archivedWorktreesSheet(ArchivedWorktreesFeature.Action)
    case archivedWorktreesSheetDismissed
    case projectPruneTapped(projectID: ProjectID, inSpace: SpaceID)
    case projectPruneCompleted(pruned: Int, error: String?)
    case pruneToastDismissed
    case worktreeRevealInFinderTapped(path: String)
    case worktreeOpenInDefaultEditorTapped(
      worktreeID: WorktreeID,
      projectID: ProjectID,
      path: String
    )

    // Add Project — scoped into AddProjectFeature via @Presents.
    case addProject(PresentationAction<AddProjectFeature.Action>)
    // Project Options — scoped into ProjectOptionsFeature via @Presents.
    case projectOptions(PresentationAction<ProjectOptionsFeature.Action>)
    // Sheet stubs
    case addWorktreeSheetDismissed
    /// Child-feature actions for the Create Worktree sheet. Parent
    /// dismisses on either delegate case (dismiss or submitted).
    case createWorktreeSheet(CreateWorktreeFeature.Action)

    // Space footer + popover
    case spaceFooterTapped
    /// External (non-footer) request to open the Space switcher popover.
    /// Open-only semantics — distinct from `.spaceFooterTapped` which is a
    /// toggle. Fires when `RootFeature` forwards `⌘K`
    /// (`.openSpaceSwitcherRequested`).
    case externalSpacePopoverOpenRequested
    case spacePopoverDismissed
    case spacePopoverSpaceSelected(SpaceID)
    /// Creates a Space with an auto-generated name (see `nextUntitledSpaceName`)
    /// and activates it. The name is computed synchronously from the current
    /// catalog snapshot just before calling `hierarchyClient.createSpace`.
    case spacePopoverNewSpaceTapped
    case spacePopoverManageSpacesTapped

    // Delegate up to RootFeature for effects that cross feature boundaries.
    case delegate(Delegate)
    @CasePathable
    enum Delegate: Equatable {
      case openInDefaultEditor(worktreePath: String, projectID: ProjectID?)
      case revealInFinder(path: String)
      /// Emitted after a Project is added (or via Retry on a `.failed` row).
      /// `RootFeature` forwards to `ProjectReconciler.reconcile`.
      case reconcileProjectRequested(ProjectID, SpaceID)
      /// Emitted from AddProjectFeature's Reveal banner. `RootFeature` selects
      /// the Space + Project so the user lands on the existing row.
      case revealExistingProject(SpaceID, ProjectID)
      case openSpaceManager
      /// M9: surfaces a lifecycle-script result on the main window. The
      /// sidebar emits this after the Archive button drives the
      /// `setWorktreeArchivedWithLifecycle` wrapper. RootFeature
      /// presents the toast.
      case lifecycleScriptResult(
        phase: SettingsWriter.WorktreeLifecycle,
        worktreeName: String,
        result: LifecycleScriptResult
      )
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(SettingsWriter.self) private var settingsWriter

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      // Parent-side handling for Create-Worktree delegate events.
      // The child reducer (attached via `.ifLet` below) runs first via
      // TCA's reducer composition order; these cases fire after the
      // child's own logic has already dispatched, so clearing
      // `createWorktreeSheet` here is the correct "dismiss the sheet"
      // effect.
      switch action {
      case .createWorktreeSheet(.delegate(.dismissed)),
        .createWorktreeSheet(.delegate(.submitted)):
        state.createWorktreeSheet = nil
        return .none
      case .createWorktreeSheet(.delegate(.lifecycleScriptResult(let phase, let name, let result))):
        // Forward the setup-script outcome up to RootFeature so the
        // toast surfaces on the main window after the sheet closes.
        return .send(
          .delegate(
            .lifecycleScriptResult(phase: phase, worktreeName: name, result: result)))
      case .createWorktreeSheet:
        // Other child actions are handled by the ifLet-scoped
        // reducer; no-op at the parent level.
        return .none
      case .archivedWorktreesSheet(.delegate(.dismissed)):
        state.archivedWorktreesSheet = nil
        return .none
      case .archivedWorktreesSheet:
        return .none
      default:
        return coreReduce(into: &state, action: action)
      }
    }
    .ifLet(\.createWorktreeSheet, action: \.createWorktreeSheet) {
      CreateWorktreeFeature()
    }
    .ifLet(\.archivedWorktreesSheet, action: \.archivedWorktreesSheet) {
      ArchivedWorktreesFeature()
    }
    .ifLet(\.$addProject, action: \.addProject) {
      AddProjectFeature()
    }
    .ifLet(\.$projectOptions, action: \.projectOptions) {
      ProjectOptionsFeature()
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func coreReduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    // MARK: Row taps

    case .spaceRowTapped(let spaceID):
      return handleSpaceSwitch(to: spaceID)

    case .projectRowTapped(let projectID, let spaceID):
      try? hierarchyClient.selectProject(projectID, spaceID)
      return .none

    case .worktreeRowTapped(let worktreeID, let projectID, let spaceID):
      // Switching worktrees across Projects must also flip
      // `space.selectedProjectID` — otherwise `currentSelection()` keeps
      // reading the previous Project's `selectedWorktreeID` and the
      // detail column never refreshes.
      try? hierarchyClient.selectProject(projectID, spaceID)
      try? hierarchyClient.selectWorktree(worktreeID, projectID, spaceID)
      // Update Space.lastActiveWorktreeID so returning to this Space later
      // restores this specific Worktree. Skip the write if the current
      // value already equals `worktreeID` — avoids waking the debounced
      // save for a no-op and keeps TestStore traces clean (don't rely
      // solely on T0's manager-side dedup).
      let snapshot = hierarchyClient.snapshot()
      if let space = snapshot.spaces.first(where: { $0.id == spaceID }),
        space.lastActiveWorktreeID != worktreeID
      {
        hierarchyClient.setSpaceLastActiveWorktree(spaceID, worktreeID)
      }
      return .none

    // MARK: Expansion

    case .toggleSpaceExpansion(let spaceID):
      if state.expandedSpaceIDs.contains(spaceID) {
        state.expandedSpaceIDs.remove(spaceID)
      } else {
        state.expandedSpaceIDs.insert(spaceID)
      }
      return .none

    case .toggleProjectExpansion(let projectID):
      // Single source of truth lives on the catalog (`Project.isExpanded`),
      // so flip via the client and let the SwiftUI catalog observation
      // re-render the row. Unknown ids are a silent no-op inside the
      // manager.
      let snapshot = hierarchyClient.snapshot()
      let current =
        snapshot.spaces
        .lazy
        .flatMap(\.projects)
        .first(where: { $0.id == projectID })?
        .isExpanded ?? true
      hierarchyClient.setProjectExpanded(projectID, !current)
      return .none

    case .pruneExpansionSets(let currentSpaceIDs):
      state.expandedSpaceIDs.formIntersection(currentSpaceIDs)
      return .none

    // MARK: Toolbar

    case .toolbarAddProjectTapped:
      if let spaceID = hierarchyClient.snapshot().selectedSpaceID {
        state.addProject = AddProjectFeature.State(targetSpaceID: spaceID)
      }
      return .none

    case .toolbarMenuTapped:
      // Placeholder — future toolbar "⋯" menu items hang here.
      return .none

    // MARK: Project hover chrome

    case .reorderProjects(let source, let destination, let spaceID):
      try? hierarchyClient.reorderProjects(spaceID, source, destination)
      return .none

    case .retryProjectTapped(let projectID, let spaceID):
      return .send(.delegate(.reconcileProjectRequested(projectID, spaceID)))

    case .projectAddWorktreeTapped(let projectID, let spaceID):
      // Resolve the Project from the catalog to feed repoRoot + worktreesDirectory
      // into CreateWorktreeFeature. v3 moved worktreesDirectory off catalog into
      // settings.json.projects[pid]. If the Project has no gitRoot the sheet wouldn't
      // be useful — silently no-op (the Add-Worktree "+" row is hidden for non-git).
      let snapshot = hierarchyClient.snapshot()
      guard let space = snapshot.spaces.first(where: { $0.id == spaceID }),
        let project = space.projects.first(where: { $0.id == projectID }),
        let gitRoot = project.gitRoot
      else { return .none }
      let wtDirOverride = settingsWriter.readSnapshotSync().projects[projectID]?.worktreesDirectory
      let defaultWtDir = URL(
        fileURLWithPath: wtDirOverride
          ?? (NSHomeDirectory() + "/.touch-code/repos/\(project.name)"))
      state.createWorktreeSheet = CreateWorktreeFeature.State(
        projectID: projectID,
        spaceID: spaceID,
        repoRoot: URL(fileURLWithPath: gitRoot),
        worktreesDirectory: defaultWtDir
      )
      return .none

    case .projectOptionsTapped(let projectID, let spaceID):
      // Snapshot the Project's current persisted values at open-time so the Options
      // reducer can skip setters for unchanged drafts. v3 reads defaultEditor /
      // worktreesDirectory from settings.json.projects[pid].
      let snapshot = hierarchyClient.snapshot()
      guard
        let project = snapshot.spaces.first(where: { $0.id == spaceID })?
          .projects.first(where: { $0.id == projectID })
      else { return .none }
      let prefs = settingsWriter.readSnapshotSync().projects[projectID]
      state.projectOptions = ProjectOptionsFeature.State(
        targetSpaceID: spaceID,
        targetProjectID: projectID,
        originalName: project.name,
        originalDefaultEditor: prefs?.defaultEditor,
        originalWorktreesDirectory: prefs?.worktreesDirectory,
        nameDraft: project.name,
        defaultEditorDraft: prefs?.defaultEditor,
        worktreesDirectoryDraft: prefs?.worktreesDirectory ?? ""
      )
      return .none

    case .projectRemoveTapped(let projectID, let spaceID, let name):
      state.pendingProjectRemoval = PendingProjectRemoval(
        projectID: projectID,
        spaceID: spaceID,
        displayName: name
      )
      return .none

    case .projectRemoveConfirmed:
      guard let pending = state.pendingProjectRemoval else { return .none }
      try? hierarchyClient.removeProject(pending.projectID, pending.spaceID)
      state.pendingProjectRemoval = nil
      return .none

    case .projectRemoveCancelled:
      state.pendingProjectRemoval = nil
      return .none

    // MARK: Worktree context menu

    case .worktreeRemoveTapped(let worktreeID, let projectID, let spaceID, let name):
      state.pendingWorktreeRemoval = PendingWorktreeRemoval(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID,
        displayName: name
      )
      return .none

    case .worktreeRemoveConfirmed:
      guard let pending = state.pendingWorktreeRemoval else { return .none }
      state.pendingWorktreeRemoval = nil
      let client = hierarchyClient
      let wid = pending.worktreeID
      let pid = pending.projectID
      let sid = pending.spaceID
      let name = pending.displayName
      return runRemoveWithDeleteScript(
        client: client, wid: wid, pid: pid, sid: sid, name: name, force: false,
        onFailure: { error in
          .worktreeRemoveFailed(
            worktreeID: wid, inProject: pid, inSpace: sid, name: name, error: error
          )
        })

    case .worktreeRemoveCancelled:
      state.pendingWorktreeRemoval = nil
      return .none

    case .worktreeRemoveFailed(let wid, let pid, let sid, let name, let error):
      // Uncommitted changes → offer Force Remove. Anything else →
      // sit the error on the root-feature delegate path as a banner
      // caller might surface; for now log silently.
      if case .uncommittedChanges(let files) = error {
        state.pendingForceRemove = PendingForceRemoval(
          worktreeID: wid,
          projectID: pid,
          spaceID: sid,
          displayName: name,
          uncommittedFiles: files
        )
      }
      return .none

    case .worktreeForceRemoveConfirmed:
      guard let pending = state.pendingForceRemove else { return .none }
      // W-Q3 ladder step 2: if live terminals, warn before hard-kill.
      let runningCount = hierarchyClient.runningPaneCount(pending.worktreeID)
      if runningCount > 0 {
        state.pendingRunningTerminalWarning = PendingRunningTerminalWarning(
          worktreeID: pending.worktreeID,
          projectID: pending.projectID,
          spaceID: pending.spaceID,
          displayName: pending.displayName,
          count: runningCount
        )
        state.pendingForceRemove = nil
        return .none
      }
      // No terminals — proceed directly.
      let client = hierarchyClient
      let wid = pending.worktreeID
      let pid = pending.projectID
      let sid = pending.spaceID
      let name = pending.displayName
      state.pendingForceRemove = nil
      return runRemoveWithDeleteScript(
        client: client, wid: wid, pid: pid, sid: sid, name: name, force: true,
        onFailure: nil)

    case .worktreeForceRemoveCancelled:
      state.pendingForceRemove = nil
      return .none

    case .worktreeRunningTerminalWarningConfirmed:
      guard let pending = state.pendingRunningTerminalWarning else { return .none }
      let client = hierarchyClient
      let wid = pending.worktreeID
      let pid = pending.projectID
      let sid = pending.spaceID
      let name = pending.displayName
      state.pendingRunningTerminalWarning = nil
      return runRemoveWithDeleteScript(
        client: client, wid: wid, pid: pid, sid: sid, name: name, force: true,
        onFailure: nil)

    case .worktreeRunningTerminalWarningCancelled:
      state.pendingRunningTerminalWarning = nil
      return .none

    case .worktreeArchiveTapped(let wid, let pid, let sid, let name):
      if state.hasShownArchiveExplainer {
        return runArchiveWithLifecycle(wid: wid, pid: pid, sid: sid, name: name)
      }
      state.pendingArchiveExplainer = PendingArchiveExplainer(
        worktreeID: wid, projectID: pid, spaceID: sid, name: name
      )
      return .none

    case .worktreeArchiveConfirmed:
      guard let pending = state.pendingArchiveExplainer else { return .none }
      state.hasShownArchiveExplainer = true
      state.pendingArchiveExplainer = nil
      return runArchiveWithLifecycle(
        wid: pending.worktreeID, pid: pending.projectID,
        sid: pending.spaceID, name: pending.name
      )

    case .worktreeArchiveCancelled:
      state.pendingArchiveExplainer = nil
      return .none

    case .worktreeUnarchiveTapped(let wid, _, _):
      try? hierarchyClient.setWorktreeArchived(wid, false)
      return .none

    case .worktreePinToggleTapped(let wid, let current):
      hierarchyClient.setWorktreePinned(wid, !current)
      return .none

    case .projectShowArchivedTapped(let projectID, let spaceID):
      state.archivedWorktreesSheet = ArchivedWorktreesFeature.State(
        projectID: projectID,
        spaceID: spaceID
      )
      return .none

    case .archivedWorktreesSheetDismissed:
      state.archivedWorktreesSheet = nil
      return .none

    case .projectPruneTapped(let projectID, let spaceID):
      let snapshot = hierarchyClient.snapshot()
      guard let space = snapshot.spaces.first(where: { $0.id == spaceID }),
        let project = space.projects.first(where: { $0.id == projectID }),
        let gitRoot = project.gitRoot
      else { return .none }
      let gitRootURL = URL(fileURLWithPath: gitRoot)
      @Dependency(GitWorktreeClient.self) var gitClient
      let client = gitClient
      return .run { send in
        do {
          let pruned = try await client.pruneWorktrees(gitRootURL)
          await send(.projectPruneCompleted(pruned: pruned, error: nil))
        } catch let error as GitWorktreeError {
          let msg: String
          if case .commandFailed(_, let stderr) = error {
            msg = stderr
          } else {
            msg = "\(error)"
          }
          await send(.projectPruneCompleted(pruned: 0, error: msg))
        } catch {
          await send(.projectPruneCompleted(pruned: 0, error: error.localizedDescription))
        }
      }

    case .projectPruneCompleted(let pruned, let error):
      if let error {
        state.pruneToast = "Prune failed: \(error)"
      } else {
        state.pruneToast =
          pruned == 1
          ? "Pruned 1 stale worktree"
          : "Pruned \(pruned) stale worktrees"
      }
      return .none

    case .pruneToastDismissed:
      state.pruneToast = nil
      return .none

    case .archivedWorktreesSheet:
      // Routed through the top-level Reducer; unreachable here.
      return .none

    case .worktreeRevealInFinderTapped(let path):
      return .send(.delegate(.revealInFinder(path: path)))

    case .worktreeOpenInDefaultEditorTapped(_, let projectID, let path):
      return .send(.delegate(.openInDefaultEditor(worktreePath: path, projectID: projectID)))

    // MARK: Add Project — scoped child

    case .addProject(.presented(.delegate(.projectAdded(let projectID, let spaceID)))):
      state.addProject = nil
      return .send(.delegate(.reconcileProjectRequested(projectID, spaceID)))

    case .addProject(.presented(.delegate(.revealExisting(let spaceID, let projectID)))):
      state.addProject = nil
      return .send(.delegate(.revealExistingProject(spaceID, projectID)))

    case .addProject(.presented(.delegate(.dismiss))), .addProject(.dismiss):
      state.addProject = nil
      return .none

    case .addProject:
      return .none

    // MARK: Project Options — scoped child

    case .projectOptions(.presented(.delegate(.dismiss))), .projectOptions(.dismiss):
      state.projectOptions = nil
      return .none

    case .projectOptions(.presented(.delegate(.saved))):
      state.projectOptions = nil
      return .none

    case .projectOptions:
      return .none

    // MARK: Sheet stubs

    case .addWorktreeSheetDismissed:
      state.addWorktreeSheet = nil
      return .none

    // MARK: Space footer + popover

    case .spaceFooterTapped:
      state.isSpacePopoverPresented.toggle()
      return .none

    case .externalSpacePopoverOpenRequested:
      state.isSpacePopoverPresented = true
      return .none

    case .spacePopoverDismissed:
      state.isSpacePopoverPresented = false
      return .none

    case .spacePopoverSpaceSelected(let spaceID):
      state.isSpacePopoverPresented = false
      return .send(.spaceRowTapped(spaceID))

    case .spacePopoverNewSpaceTapped:
      let snapshot = hierarchyClient.snapshot()
      let name = nextUntitledSpaceName(in: snapshot.spaces)
      let newID = hierarchyClient.createSpace(name)
      hierarchyClient.selectSpace(newID)
      state.isSpacePopoverPresented = false
      return .none

    case .spacePopoverManageSpacesTapped:
      state.isSpacePopoverPresented = false
      return .send(.delegate(.openSpaceManager))

    // MARK: Delegate

    case .delegate:
      // Handled by the parent reducer.
      return .none

    case .createWorktreeSheet:
      // Routed through the top-level Reducer; unreachable here.
      return .none
    }
  }

  /// Space-switch choreography. See design doc §Alternatives A — lives in the
  /// sidebar reducer (not in `RootFeature.selectionChanged`) because we need
  /// to read the outgoing `worktreeID` *before* `selectSpace` mutates the
  /// catalog.
  ///
  /// Steps:
  /// 1. No-op if already on the target Space.
  /// 2. Write outgoing Space's `lastActiveWorktreeID` = currently selected
  ///    worktree under that Space (may be nil; the manager-side dedup drops
  ///    a nil→nil write).
  /// 3. `selectSpace(target)`.
  /// 4. Read the target Space's `lastActiveWorktreeID`. If it still resolves
  ///    to a Worktree in the post-switch snapshot, `selectWorktree` it.
  ///    Otherwise clear the stale pointer and let the existing
  ///    `Project.selectedWorktreeID` fallback take effect on the next
  ///    selection-stream observation.
  private func handleSpaceSwitch(to spaceID: SpaceID) -> Effect<Action> {
    let outgoingSnapshot = hierarchyClient.snapshot()
    guard outgoingSnapshot.selectedSpaceID != spaceID else { return .none }

    // Write outgoing lastActive = outgoing selection's worktreeID.
    if let outgoingSpaceID = outgoingSnapshot.selectedSpaceID,
      let outgoingSpace = outgoingSnapshot.spaces.first(where: { $0.id == outgoingSpaceID })
    {
      let outgoingWorktreeID = outgoingSpace.projects
        .first(where: { $0.id == outgoingSpace.selectedProjectID })?
        .selectedWorktreeID
      hierarchyClient.setSpaceLastActiveWorktree(outgoingSpaceID, outgoingWorktreeID)
    }

    hierarchyClient.selectSpace(spaceID)

    // Resolve target's lastActiveWorktreeID against the post-switch snapshot.
    let postSnapshot = hierarchyClient.snapshot()
    guard let targetSpace = postSnapshot.spaces.first(where: { $0.id == spaceID }),
      let lastID = targetSpace.lastActiveWorktreeID
    else { return .none }

    for project in targetSpace.projects
    where project.worktrees.contains(where: { $0.id == lastID }) {
      try? hierarchyClient.selectWorktree(lastID, project.id, spaceID)
      return .none
    }
    // Stale — clear the pointer and let Project.selectedWorktreeID fallback take over.
    hierarchyClient.setSpaceLastActiveWorktree(spaceID, nil)
    return .none
  }

  /// M9: Archive button → wrapper variant. The wrapper runs the archive
  /// script (fail-warn) and flips `Worktree.archived = true` regardless
  /// of script exit. Surfaces the result as a delegate event so
  /// `RootFeature` can present the toast.
  private func runArchiveWithLifecycle(
    wid: WorktreeID, pid: ProjectID, sid: SpaceID, name: String
  ) -> Effect<Action> {
    let client = hierarchyClient
    return .run { send in
      let result =
        (try? await client.setWorktreeArchivedWithLifecycle(wid, pid, true)) ?? .skipped
      await send(
        .delegate(
          .lifecycleScriptResult(phase: .archive, worktreeName: name, result: result))
      )
    }
  }

  /// M9: Remove button → script-only delete-script execution before the
  /// gh-aware `removeWorktreeWithGit` call. Mirrors `CreateWorktreeFeature`'s
  /// setup-script pattern: the lifecycle wrapper is bypassed because the
  /// remove path needs the gh-aware variant (`git worktree remove`), not
  /// the catalog-only `removeWorktree`. Fail-warn semantics — script
  /// failure does not block the remove. `onFailure` is non-nil for the
  /// safe path (so uncommitted-changes errors can ladder into the
  /// force-remove flow); the force paths swallow remove errors directly.
  private func runRemoveWithDeleteScript(
    client: HierarchyClient,
    wid: WorktreeID, pid: ProjectID, sid: SpaceID, name: String, force: Bool,
    onFailure: (@Sendable (GitWorktreeError) -> Action)?
  ) -> Effect<Action> {
    .run { send in
      let result = await client.runWorktreeLifecycleScript(.delete, wid, pid)
      await send(
        .delegate(
          .lifecycleScriptResult(phase: .delete, worktreeName: name, result: result))
      )
      do {
        try await client.removeWorktreeWithGit(wid, pid, sid, force)
      } catch let error as GitWorktreeError {
        if let onFailure {
          await send(onFailure(error))
        }
      } catch {
        if let onFailure {
          await send(
            onFailure(
              .commandFailed(command: "remove", stderr: error.localizedDescription)))
        }
      }
    }
  }
}
