import ComposableArchitecture
import Foundation
import TouchCodeCore

// MARK: - Transient sheet / dialog payloads

/// Stub-sheet payload for Project-header "+" (add Worktree). Retained
/// for the brief window between `.projectAddWorktreeTapped` firing and
/// the real `CreateWorktreeFeature.State` being seeded in the next
/// reducer step. Carries just the parent IDs needed to resolve the
/// Project from `HierarchyManager.catalog` when building the child state.
struct AddWorktreeSheet: Equatable {
  var projectID: ProjectID
}

/// Worktree-remove confirmation payload. Non-nil → `.confirmationDialog` visible.
/// `displayName` is captured at tap-time so the dialog title shows the correct
/// name even if the catalog mutates before the user confirms.
struct PendingWorktreeRemoval: Equatable {
  var worktreeID: WorktreeID
  var projectID: ProjectID
  var displayName: String
}

/// Project-remove confirmation payload. Symmetric to `PendingWorktreeRemoval`
/// — Remove Project transitively removes every child Worktree, killing their
/// terminal surfaces, so we gate it with the same confirm pattern.
struct PendingProjectRemoval: Equatable {
  var projectID: ProjectID
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
    // Project disclosure state lives on `Project.isExpanded` so the open /
    // closed choice survives restart — the view reads `project.isExpanded`
    // directly from the catalog, mirroring how `Worktree.isPinned` is
    // consumed.

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
    /// Session-scoped "seen it" flag for the first-archive explainer.
    /// Lives on this reducer (sidebar is the sole archive entry point
    /// for the main list; Archived sheet handles its own flow).
    var hasShownArchiveExplainer: Bool = false
    /// Pending archive awaiting the first-archive explainer dialog.
    var pendingArchiveExplainer: PendingArchiveExplainer?
    /// Transient toast after Prune completes.
    var pruneToast: String?
    /// In-memory placeholders for in-flight `wt sw` creations. Each row
    /// renders inside its Project's section between pinned and unpinned
    /// segments. Not persisted; an app restart clears the set, and the
    /// existing reconcile path picks up any worktree that did make it to
    /// disk before the crash. See `docs/design-docs/worktree-sidebar-ordering.md`
    /// §pending 段.
    var pendingWorktrees: IdentifiedArrayOf<PendingWorktree> = []
  }

  /// Payload for the first-archive explainer dialog. Carries the
  /// originating `(projectID, name)` so the post-confirm path
  /// can run the archive-script wrapper without re-walking the catalog.
  struct PendingArchiveExplainer: Equatable {
    var worktreeID: WorktreeID
    var projectID: ProjectID
    var name: String
  }

  enum Action: Equatable {
    // Row taps
    case projectRowTapped(ProjectID)
    case worktreeRowTapped(WorktreeID, inProject: ProjectID)

    // Expansion
    case toggleProjectExpansion(ProjectID)

    // Toolbar
    case toolbarAddProjectTapped

    // Reorder Projects (ForEach.onMove forwarder).
    case reorderProjects(from: IndexSet, to: Int)

    // Reorder Worktrees within a single sidebar segment under a Project
    // (ForEach.onMove forwarder for the pinned / unpinned segments).
    case reorderWorktrees(
      projectID: ProjectID,
      segment: WorktreeSegment, from: IndexSet, to: Int
    )

    /// Fired from `FailedProjectRow.Retry` (or the context menu). Delegates
    /// to `RootFeature` which calls `ProjectReconciler.reconcile` — same path
    /// used after Add Project.
    case retryProjectTapped(projectID: ProjectID)

    // Project section hover chrome
    case projectAddWorktreeTapped(projectID: ProjectID)
    /// Open the Project Options sheet for the given row. Replaces the
    /// standalone Rename Project sheet actions (P-Q2 = a).
    case projectOptionsTapped(projectID: ProjectID)
    case projectRemoveTapped(projectID: ProjectID, name: String)
    case projectRemoveConfirmed
    case projectRemoveCancelled

    // Worktree row context menu
    case worktreeRemoveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      name: String
    )
    case worktreeRemoveConfirmed
    case worktreeRemoveCancelled

    // Archive actions on the main worktree row.
    case worktreeArchiveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID,
      name: String
    )
    case worktreeArchiveConfirmed
    case worktreeArchiveCancelled
    case worktreeUnarchiveTapped(
      worktreeID: WorktreeID,
      inProject: ProjectID
    )
    /// Right-click menu toggle. Flips the Worktree's `isPinned` flag via `HierarchyClient`.
    /// The `current` parameter lets the reducer emit the opposite value without reading
    /// catalog state.
    case worktreePinToggleTapped(worktreeID: WorktreeID, current: Bool)

    // Project ⋯ menu: Archived + Prune.
    case projectShowArchivedTapped(projectID: ProjectID)
    case archivedWorktreesSheet(ArchivedWorktreesFeature.Action)
    case archivedWorktreesSheetDismissed
    case projectPruneTapped(projectID: ProjectID)
    case projectPruneCompleted(pruned: Int, error: String?)
    case pruneToastDismissed
    case worktreeRevealInFinderTapped(path: String)
    case worktreeOpenInDefaultEditorTapped(
      worktreeID: WorktreeID,
      projectID: ProjectID,
      path: String
    )

    // Pending-worktree lifecycle. See worktree-sidebar-ordering.md §pending 段.
    case beginPendingWorktreeCreation(PendingWorktree)
    case pendingWorktreeProgress(PendingWorktreeID, String)
    case pendingWorktreeFinished(PendingWorktreeID, URL)
    case pendingWorktreeFailed(PendingWorktreeID, GitWorktreeError)
    case pendingWorktreeRetryTapped(PendingWorktreeID)
    case pendingWorktreeDiscardTapped(PendingWorktreeID)
    case pendingWorktreeCancelTapped(PendingWorktreeID)

    // M4: Tag chip footer at the sidebar's safe-area bottom.
    /// Toggle membership of `id` in `Catalog.activeTagFilter`. If filter is
    /// `.all` or `.untagged` it becomes `.tags([id])`. Within `.tags(set)`,
    /// `id` toggles in/out; an empty result resets to `.all`.
    case tagChipTapped(TagID)
    /// Resets the filter to `.all`.
    case allChipTapped
    /// Sets filter to `.untagged`. Mutually exclusive with `.tags(...)`.
    case untaggedChipTapped
    /// Bound to ⌘F via `MainWindowCommands`. Routed up so the chip footer
    /// view can take focus.
    case tagFilterFocusRequested

    // Add Project — scoped into AddProjectFeature via @Presents.
    case addProject(PresentationAction<AddProjectFeature.Action>)
    // Project Options — scoped into ProjectOptionsFeature via @Presents.
    case projectOptions(PresentationAction<ProjectOptionsFeature.Action>)
    // Sheet stubs
    case addWorktreeSheetDismissed
    /// Child-feature actions for the Create Worktree sheet. Parent
    /// dismisses on either delegate case (dismiss or submitted).
    case createWorktreeSheet(CreateWorktreeFeature.Action)

    // Delegate up to RootFeature for effects that cross feature boundaries.
    case delegate(Delegate)
    @CasePathable
    enum Delegate: Equatable {
      case openInDefaultEditor(worktreePath: String, projectID: ProjectID?)
      case revealInFinder(path: String)
      /// Emitted after a Project is added (or via Retry on a `.failed` row).
      /// `RootFeature` forwards to `ProjectReconciler.reconcile`.
      case reconcileProjectRequested(ProjectID)
      /// Emitted from AddProjectFeature's Reveal banner. `RootFeature` selects
      /// the Project so the user lands on the existing row.
      case revealExistingProject(ProjectID)
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
  @Dependency(GitWorktreeClient.self) private var gitWorktreeClient

  /// Cancellation token namespace for sidebar-owned effects. The single
  /// `.pending` case ties each in-flight `wt sw` stream to its
  /// `PendingWorktreeID` so Cancel / Retry can target it precisely.
  /// `nonisolated` because TCA's `.cancellable(id:)` requires a Sendable
  /// id; the reducer's default MainActor isolation would otherwise gate
  /// the conformance.
  private nonisolated enum CancelID: Hashable, Sendable {
    case pending(PendingWorktreeID)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      // Parent-side handling for Create-Worktree delegate events.
      // The child reducer (attached via `.ifLet` below) runs first via
      // TCA's reducer composition order; these cases fire after the
      // child's own logic has already dispatched, so clearing
      // `createWorktreeSheet` here is the correct "dismiss the sheet"
      // effect.
      switch action {
      case .createWorktreeSheet(.delegate(.dismissed)):
        state.createWorktreeSheet = nil
        return .none
      case .createWorktreeSheet(.delegate(.beginCreate(let pending))):
        // Sheet validated the form; parent dismisses and starts the
        // pending lifecycle in the same reducer frame so the user never
        // sees a "sheet closed but row not yet present" gap.
        state.createWorktreeSheet = nil
        return .send(.beginPendingWorktreeCreation(pending))
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

    case .projectRowTapped(let projectID):
      try? hierarchyClient.selectProject(projectID)
      return .none

    case .worktreeRowTapped(let worktreeID, let projectID):
      // Switching worktrees across Projects must also flip the active
      // Project — otherwise selection keeps reading the previous Project's
      // `selectedWorktreeID` and the detail column never refreshes.
      try? hierarchyClient.selectProject(projectID)
      try? hierarchyClient.selectWorktree(worktreeID, projectID)
      return .none

    // MARK: Expansion

    case .toggleProjectExpansion(let projectID):
      // Single source of truth lives on the catalog (`Project.isExpanded`),
      // so flip via the client and let the SwiftUI catalog observation
      // re-render the row. Unknown ids are a silent no-op inside the
      // manager.
      let snapshot = hierarchyClient.snapshot()
      let current =
        snapshot.projects
        .first(where: { $0.id == projectID })?
        .isExpanded ?? true
      hierarchyClient.setProjectExpanded(projectID, !current)
      return .none

    // MARK: Toolbar

    case .toolbarAddProjectTapped:
      state.addProject = AddProjectFeature.State()
      return .none

    // MARK: Tag filter chip footer (M4)

    case .tagChipTapped(let tagID):
      let current = hierarchyClient.snapshot().activeTagFilter
      let next: TagFilter
      switch current {
      case .all, .untagged:
        next = .tags([tagID])
      case .tags(let set):
        if set.contains(tagID) {
          var updated = set
          updated.remove(tagID)
          next = updated.isEmpty ? .all : .tags(updated)
        } else {
          var updated = set
          updated.insert(tagID)
          next = .tags(updated)
        }
      }
      hierarchyClient.setActiveTagFilter(next)
      return .none

    case .allChipTapped:
      hierarchyClient.setActiveTagFilter(.all)
      return .none

    case .untaggedChipTapped:
      hierarchyClient.setActiveTagFilter(.untagged)
      return .none

    case .tagFilterFocusRequested:
      // The view subscribes to this via `@FocusState`; the reducer is a
      // pure pass-through so the feature stays state-light.
      return .none

    // MARK: Project hover chrome

    case .reorderProjects(let source, let destination):
      try? hierarchyClient.reorderProjects(source, destination)
      return .none

    case .reorderWorktrees(let projectID, let segment, let source, let destination):
      try? hierarchyClient.reorderWorktrees(projectID, segment, source, destination)
      return .none

    case .retryProjectTapped(let projectID):
      return .send(.delegate(.reconcileProjectRequested(projectID)))

    case .projectAddWorktreeTapped(let projectID):
      // Resolve the Project from the catalog to feed repoRoot + worktreesDirectory
      // into CreateWorktreeFeature. v3 moved worktreesDirectory off catalog into
      // settings.json.projects[pid]. If the Project has no gitRoot the sheet wouldn't
      // be useful — silently no-op (the Add-Worktree "+" row is hidden for non-git).
      let snapshot = hierarchyClient.snapshot()
      guard let project = snapshot.projects.first(where: { $0.id == projectID }),
        let gitRoot = project.gitRoot
      else { return .none }
      let wtDirOverride = settingsWriter.readSnapshotSync().projects[projectID]?.worktreesDirectory
      let defaultWtDir = URL(
        fileURLWithPath: wtDirOverride
          ?? (NSHomeDirectory() + "/.touch-code/repos/\(project.name)"))
      let pendingCount = state.pendingWorktrees.filter { $0.projectID == projectID }.count
      state.createWorktreeSheet = CreateWorktreeFeature.State(
        projectID: projectID,
        repoRoot: URL(fileURLWithPath: gitRoot),
        worktreesDirectory: defaultWtDir,
        currentPendingCountForProject: pendingCount
      )
      return .none

    case .projectOptionsTapped(let projectID):
      // Snapshot the Project's current persisted values at open-time so the Options
      // reducer can skip setters for unchanged drafts. v3 reads defaultEditor /
      // worktreesDirectory from settings.json.projects[pid].
      let snapshot = hierarchyClient.snapshot()
      guard
        let project = snapshot.projects.first(where: { $0.id == projectID })
      else { return .none }
      let prefs = settingsWriter.readSnapshotSync().projects[projectID]
      state.projectOptions = ProjectOptionsFeature.State(
        targetProjectID: projectID,
        originalName: project.name,
        originalDefaultEditor: prefs?.defaultEditor,
        originalWorktreesDirectory: prefs?.worktreesDirectory,
        nameDraft: project.name,
        defaultEditorDraft: prefs?.defaultEditor,
        worktreesDirectoryDraft: prefs?.worktreesDirectory ?? ""
      )
      return .none

    case .projectRemoveTapped(let projectID, let name):
      state.pendingProjectRemoval = PendingProjectRemoval(
        projectID: projectID,
        displayName: name
      )
      return .none

    case .projectRemoveConfirmed:
      guard let pending = state.pendingProjectRemoval else { return .none }
      try? hierarchyClient.removeProject(pending.projectID)
      state.pendingProjectRemoval = nil
      return .none

    case .projectRemoveCancelled:
      state.pendingProjectRemoval = nil
      return .none

    // MARK: Worktree context menu

    case .worktreeRemoveTapped(let worktreeID, let projectID, let name):
      state.pendingWorktreeRemoval = PendingWorktreeRemoval(
        worktreeID: worktreeID,
        projectID: projectID,
        displayName: name
      )
      return .none

    case .worktreeRemoveConfirmed:
      guard let pending = state.pendingWorktreeRemoval else { return .none }
      state.pendingWorktreeRemoval = nil
      let client = hierarchyClient
      let wid = pending.worktreeID
      let pid = pending.projectID
      let name = pending.displayName
      return runRemoveWithDeleteScript(
        client: client, wid: wid, pid: pid, name: name
      )

    case .worktreeRemoveCancelled:
      state.pendingWorktreeRemoval = nil
      return .none

    case .worktreeArchiveTapped(let wid, let pid, let name):
      if state.hasShownArchiveExplainer {
        return runArchiveWithLifecycle(wid: wid, pid: pid, name: name)
      }
      state.pendingArchiveExplainer = PendingArchiveExplainer(
        worktreeID: wid, projectID: pid, name: name
      )
      return .none

    case .worktreeArchiveConfirmed:
      guard let pending = state.pendingArchiveExplainer else { return .none }
      state.hasShownArchiveExplainer = true
      state.pendingArchiveExplainer = nil
      return runArchiveWithLifecycle(
        wid: pending.worktreeID, pid: pending.projectID,
        name: pending.name
      )

    case .worktreeArchiveCancelled:
      state.pendingArchiveExplainer = nil
      return .none

    case .worktreeUnarchiveTapped(let wid, _):
      try? hierarchyClient.setWorktreeArchived(wid, false)
      return .none

    case .worktreePinToggleTapped(let wid, let current):
      hierarchyClient.setWorktreePinned(wid, !current)
      return .none

    case .projectShowArchivedTapped(let projectID):
      state.archivedWorktreesSheet = ArchivedWorktreesFeature.State(
        projectID: projectID
      )
      return .none

    case .archivedWorktreesSheetDismissed:
      state.archivedWorktreesSheet = nil
      return .none

    case .projectPruneTapped(let projectID):
      let snapshot = hierarchyClient.snapshot()
      guard let project = snapshot.projects.first(where: { $0.id == projectID }),
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

    case .addProject(.presented(.delegate(.projectAdded(let projectID)))):
      state.addProject = nil
      return .send(.delegate(.reconcileProjectRequested(projectID)))

    case .addProject(.presented(.delegate(.revealExisting(let projectID)))):
      state.addProject = nil
      return .send(.delegate(.revealExistingProject(projectID)))

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

    // MARK: Pending worktree lifecycle

    case .beginPendingWorktreeCreation(let pending):
      // Hard cap (master doc Risks): silently reject when this project
      // already has 8 pending creations. The sheet UI also enforces this
      // via banner + disabled Create; reducer guard covers non-sheet
      // entry points (IPC, command palette, tests).
      let count = state.pendingWorktrees.filter { $0.projectID == pending.projectID }.count
      guard count < 8 else { return .none }
      state.pendingWorktrees.append(pending)
      return runPendingStream(pending)

    case .pendingWorktreeProgress(let id, let line):
      // Race guard: cancel may have removed the row before this progress
      // line drained from the stream.
      guard state.pendingWorktrees[id: id] != nil else { return .none }
      state.pendingWorktrees[id: id]?.lastProgressLine = line
      return .none

    case .pendingWorktreeFinished(let id, let path):
      guard let pending = state.pendingWorktrees[id: id] else { return .none }
      let pid = pending.projectID
      let branch = pending.spec.branch
      let directoryName = pending.spec.name
      let pathString = path.standardizedFileURL.path(percentEncoded: false)

      // Critical boundary: catalog write. Failure here keeps the row
      // visible as .failed for Retry/Discard. Anything below is cosmetic.
      let worktreeID: WorktreeID
      do {
        worktreeID = try hierarchyClient.createWorktreeWithGit(
          pid, branch, directoryName, pathString)
      } catch let err as GitWorktreeError {
        state.pendingWorktrees[id: id]?.status = .failed(err)
        return .none
      } catch {
        state.pendingWorktrees[id: id]?.status = .failed(
          .commandFailed(command: "catalog", stderr: error.localizedDescription))
        return .none
      }

      // Catalog now has the real worktree row. Remove pending IMMEDIATELY
      // so the sidebar doesn't double-render (real row + .failed pending
      // row for the same logical creation). The post-catalog steps below
      // are cosmetic side-effects and must not roll back this removal.
      state.pendingWorktrees.remove(id: id)
      try? hierarchyClient.selectWorktree(worktreeID, pid)
      if let tabID = try? hierarchyClient.createTab(worktreeID, pid, nil) {
        _ = try? hierarchyClient.openPane(tabID, worktreeID, pid, pathString, nil)
      }

      // Setup script fires regardless of cosmetic-step outcomes — the
      // worktree is real on disk + in catalog, its setup hook should run.
      let client = hierarchyClient
      return .run { send in
        let result = await client.runWorktreeLifecycleScript(.setup, worktreeID, pid)
        await send(
          .delegate(
            .lifecycleScriptResult(phase: .setup, worktreeName: branch, result: result)))
      }

    case .pendingWorktreeFailed(let id, let err):
      // Race guard symmetric with progress / finished arms: a Cancel
      // that lands before the stream's failure event drains drops the
      // late .failed without spuriously logging or mutating state.
      guard state.pendingWorktrees[id: id] != nil else { return .none }
      state.pendingWorktrees[id: id]?.status = .failed(err)
      return .none

    case .pendingWorktreeRetryTapped(let id):
      guard let pending = state.pendingWorktrees[id: id] else { return .none }
      guard case .failed = pending.status else { return .none }
      state.pendingWorktrees[id: id]?.status = .running
      state.pendingWorktrees[id: id]?.lastProgressLine = nil
      // Re-read the (now-updated) row so the effect sees `status == .running`.
      guard let restarted = state.pendingWorktrees[id: id] else { return .none }
      return runPendingStream(restarted)

    case .pendingWorktreeDiscardTapped(let id):
      state.pendingWorktrees.remove(id: id)
      return .none

    case .pendingWorktreeCancelTapped(let id):
      state.pendingWorktrees.remove(id: id)
      return .cancel(id: CancelID.pending(id))

    // MARK: Delegate

    case .delegate:
      // Handled by the parent reducer.
      return .none

    case .createWorktreeSheet:
      // Routed through the top-level Reducer; unreachable here.
      return .none
    }
  }

  /// Cancellable streaming effect that consumes `createWorktreeStream`
  /// for a single pending creation. Cancel-in-flight protects Retry from
  /// overlapping a zombie effect (edge case — by the time Retry fires
  /// the prior effect should already have thrown).
  private func runPendingStream(_ pending: PendingWorktree) -> Effect<Action> {
    let client = gitWorktreeClient
    let id = pending.id
    return .run { send in
      do {
        for try await event in client.createWorktreeStream(pending.spec) {
          switch event {
          case .progressLine(let line):
            await send(.pendingWorktreeProgress(id, line))
          case .finished(let url):
            await send(.pendingWorktreeFinished(id, url))
            return
          }
        }
        await send(
          .pendingWorktreeFailed(
            id, .commandFailed(command: "wt sw", stderr: "stream ended without finishing")))
      } catch let err as GitWorktreeError {
        await send(.pendingWorktreeFailed(id, err))
      } catch is CancellationError {
        return
      } catch {
        await send(
          .pendingWorktreeFailed(
            id, .commandFailed(command: "wt sw", stderr: error.localizedDescription)))
      }
    }
    .cancellable(id: CancelID.pending(id), cancelInFlight: true)
  }

  /// M9: Archive button → wrapper variant. The wrapper runs the archive
  /// script (fail-warn) and flips `Worktree.archived = true` regardless
  /// of script exit. Surfaces the result as a delegate event so
  /// `RootFeature` can present the toast.
  private func runArchiveWithLifecycle(
    wid: WorktreeID, pid: ProjectID, name: String
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

  /// Remove button → run the configured `delete` lifecycle script (if
  /// any), surface its result via the lifecycle toast, then drive the
  /// relocate-then-prune git removal in `removeWorktreeWithGit`. The
  /// git step has no "uncommitted changes" or "submodule" guard
  /// anymore — the worktree directory is moved out of the way before
  /// `git worktree prune` is asked to clean the metadata — so a single
  /// confirmation in the UI is the only protection. Errors are
  /// swallowed: a failed remove leaves the worktree in place but does
  /// not surface a banner (mirrors supacode's `try?` semantics; see
  /// design discussion 2026-04-27).
  private func runRemoveWithDeleteScript(
    client: HierarchyClient,
    wid: WorktreeID, pid: ProjectID, name: String
  ) -> Effect<Action> {
    .run { send in
      let result = await client.runWorktreeLifecycleScript(.delete, wid, pid)
      await send(
        .delegate(
          .lifecycleScriptResult(phase: .delete, worktreeName: name, result: result))
      )
      try? await client.removeWorktreeWithGit(wid, pid)
    }
  }
}
