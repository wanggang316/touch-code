import Foundation
import Observation
import TouchCodeCore

enum HierarchyError: Error, Equatable, Sendable {
  case notFound(String)
  case invariantViolation(String)
}

@MainActor
@Observable
final class HierarchyManager {
  private(set) var catalog: Catalog
  private let store: CatalogStore
  private let runtime: HierarchyRuntime

  /// Runtime-only map of the pane the user most recently focused inside a
  /// given tab. Read by `selectTab` to restore focus on tab switches;
  /// cleared when the pane or the tab is closed. Never persisted — wall-
  /// clock-live state that must be rebuilt each launch.
  private var lastFocusedPaneByTab: [TabID: PaneID] = [:]

  /// Runtime-only set of panes that are currently executing a tracked
  /// command. Driven by C3 hooks in a future milestone; today the only
  /// writers are the `markPaneRunning` / `markPaneIdle` methods, which no
  /// caller invokes in production. Reads via `tabIsDirty(_:)` still work
  /// — they return `false` uniformly until a writer wakes up. Stored as a
  /// `Set` rather than `[PaneID: Bool]` so absence is the natural "idle"
  /// signal and `contains` is the only read shape.
  private var runningPanes: Set<PaneID> = []

  init(catalog: Catalog, store: CatalogStore, runtime: HierarchyRuntime) {
    self.catalog = catalog
    self.store = store
    self.runtime = runtime
  }

  // MARK: - Space mutations

  func createSpace(name: String) -> SpaceID {
    let spaceID = SpaceID()
    let space = Space(id: spaceID, name: name, projects: [], selectedProjectID: nil)
    catalog.spaces.append(space)
    catalog.selectedSpaceID = spaceID
    store.scheduleSave(catalog)
    return spaceID
  }

  func renameSpace(_ id: SpaceID, name: String) throws {
    guard let index = catalog.spaces.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Space \(id)")
    }
    catalog.spaces[index].name = name
    store.scheduleSave(catalog)
  }

  func removeSpace(_ id: SpaceID) throws {
    guard let index = catalog.spaces.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Space \(id)")
    }
    catalog.spaces.remove(at: index)
    if catalog.selectedSpaceID == id {
      catalog.selectedSpaceID = catalog.spaces.first?.id
    }
    store.scheduleSave(catalog)
  }

  func selectSpace(_ id: SpaceID?) {
    catalog.selectedSpaceID = id
    store.scheduleSave(catalog)
  }

  /// Records which Worktree to restore when the window re-activates this Space.
  /// Pass `nil` to clear. Missing `spaceID` is a silent no-op; unchanged value
  /// is a silent no-op (no save scheduled). Persists via the standard
  /// debounced `store.scheduleSave(catalog)` pipeline used by every other
  /// catalog mutation.
  func setSpaceLastActiveWorktree(spaceID: SpaceID, worktreeID: WorktreeID?) {
    guard let index = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
    guard catalog.spaces[index].lastActiveWorktreeID != worktreeID else { return }
    catalog.spaces[index].lastActiveWorktreeID = worktreeID
    store.scheduleSave(catalog)
  }

  /// Reorder Spaces using the IndexSet (source) and destination offset payload
  /// from SwiftUI's `.onMove(perform:)`. Silent no-op on empty IndexSet.
  /// Persists via the standard debounced `store.scheduleSave` pipeline.
  func reorderSpaces(fromOffsets source: IndexSet, toOffset destination: Int) {
    guard !source.isEmpty else { return }
    catalog.spaces.move(fromOffsets: source, toOffset: destination)
    store.scheduleSave(catalog)
  }

  // MARK: - Project mutations

  func addProject(to spaceID: SpaceID, name: String, rootPath: String, gitRoot: String? = nil) throws -> ProjectID {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
      throw HierarchyError.notFound("Space \(spaceID)")
    }

    let projectID = ProjectID()
    var worktrees: [Worktree] = []
    var selectedWorktreeID: WorktreeID?

    if gitRoot == nil {
      let synthetic = Worktree(
        id: WorktreeID(),
        name: (rootPath as NSString).lastPathComponent,
        path: rootPath,
        branch: nil,
        tabs: [],
        selectedTabID: nil
      )
      worktrees = [synthetic]
      selectedWorktreeID = synthetic.id
    }

    let project = Project(
      id: projectID,
      name: name,
      rootPath: rootPath,
      gitRoot: gitRoot,
      worktreesDirectory: nil,
      defaultEditor: nil,
      worktrees: worktrees,
      selectedWorktreeID: selectedWorktreeID
    )
    catalog.spaces[spaceIndex].projects.append(project)
    catalog.spaces[spaceIndex].selectedProjectID = projectID
    store.scheduleSave(catalog)
    return projectID
  }

  /// Renames the Project in place. Missing project is `.notFound`; an unchanged
  /// name is a silent no-op (no catalog churn, no save). The caller is
  /// responsible for trimming / empty-string validation — matches `renameSpace`.
  func renameProject(_ id: ProjectID, in spaceID: SpaceID, name: String) throws {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: id, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(id)")
    }
    guard catalog.spaces[spaceIndex].projects[projectIndex].name != name else { return }
    catalog.spaces[spaceIndex].projects[projectIndex].name = name
    store.scheduleSave(catalog)
  }

  func removeProject(_ id: ProjectID, from spaceID: SpaceID) throws {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
      throw HierarchyError.notFound("Space \(spaceID)")
    }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Project \(id)")
    }

    catalog.spaces[spaceIndex].projects.remove(at: projectIndex)
    if catalog.spaces[spaceIndex].selectedProjectID == id {
      catalog.spaces[spaceIndex].selectedProjectID = catalog.spaces[spaceIndex].projects.first?.id
    }
    store.scheduleSave(catalog)
  }

  func selectProject(_ id: ProjectID?, in spaceID: SpaceID) throws {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
      throw HierarchyError.notFound("Space \(spaceID)")
    }
    catalog.spaces[spaceIndex].selectedProjectID = id
    store.scheduleSave(catalog)
  }

  /// Sets or unsets the per-Project default editor. `nil` clears the override so editor
  /// resolution falls back to the global default (managed by `SettingsStore`) and ultimately
  /// Transient Project-level health state owned by `ProjectReconciler`. Never
  /// persisted (`Project.loadState` is a transient field); equal-value writes
  /// are dropped so repeated reconciliations don't churn the catalog graph.
  func setProjectLoadState(
    _ state: ProjectLoadState,
    projectID: ProjectID,
    spaceID: SpaceID
  ) {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else { return }
    guard catalog.spaces[spaceIndex].projects[projectIndex].loadState != state else { return }
    catalog.spaces[spaceIndex].projects[projectIndex].loadState = state
    // No scheduleSave — transient.
  }

  /// Reorder Projects inside a Space. Mirrors SwiftUI `ForEach.onMove`'s
  /// `(IndexSet, Int)` signature so the sidebar can forward directly. Missing
  /// Space is `.notFound`; Array's `move(fromOffsets:toOffset:)` already
  /// handles out-of-range destinations by trapping — callers must pass a
  /// valid index. Persists.
  func reorderProjects(
    in spaceID: SpaceID,
    from source: IndexSet,
    to destination: Int
  ) throws {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else {
      throw HierarchyError.notFound("Space \(spaceID)")
    }
    catalog.spaces[spaceIndex].projects.move(fromOffsets: source, toOffset: destination)
    store.scheduleSave(catalog)
  }

  /// Resolves a canonical path to its registered `(SpaceID, ProjectID)` if any
  /// Project's `rootPath` canonicalizes to the same form. Caller canonicalizes
  /// its input via `HierarchyManager.canonicalPath(_:)` before querying.
  /// Linear in total Project count — acceptable at the low cardinality we
  /// support (Projects per user, not per repo).
  func isPathRegistered(canonical path: String) -> (SpaceID, ProjectID)? {
    for space in catalog.spaces {
      for project in space.projects where Self.canonicalPath(project.rootPath) == path {
        return (space.id, project.id)
      }
    }
    return nil
  }

  /// Resolves a canonical path to the `(SpaceID, ProjectID)` whose `rootPath`
  /// **contains** `path` — i.e. the path is the root itself or a descendant.
  /// Used by the `editor.open` IPC so `tc open` inside a subdirectory of a
  /// registered Project still honors the Project's `defaultEditor` override;
  /// `isPathRegistered` only matches the exact root.
  ///
  /// Matching is on path-segment boundaries: `/repo` matches `/repo` and
  /// `/repo/src/` but not `/repository`. When Projects nest (rare but legal —
  /// a monorepo Project with a sub-repo Project under it), the deepest match
  /// wins so the closest override is applied.
  ///
  /// Caller canonicalizes via `HierarchyManager.canonicalPath(_:)` before
  /// querying. Linear in total Project count like `isPathRegistered`.
  func project(containing path: String) -> (SpaceID, ProjectID)? {
    var best: (SpaceID, ProjectID, Int)?  // (space, project, root length)
    for space in catalog.spaces {
      for project in space.projects {
        let root = Self.canonicalPath(project.rootPath)
        guard path == root || path.hasPrefix(root + "/") else { continue }
        if best == nil || root.count > best!.2 {
          best = (space.id, project.id, root.count)
        }
      }
    }
    return best.map { ($0.0, $0.1) }
  }

  // MARK: - Worktree mutations

  func createWorktree(
    in projectID: ProjectID,
    in spaceID: SpaceID,
    name: String,
    path: String,
    branch: String?
  ) throws -> WorktreeID {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }

    // Canonicalize at the single write boundary so every downstream
    // comparison (main-checkout guard, reconcile dedupe, selection
    // lookups) sees the same symlink-resolved form that
    // `Project.rootPath` already stores. Caller-side canonicalization
    // is easy to forget; doing it here means the API is self-correcting.
    let canonicalizedPath = Self.canonicalPath(path)
    let worktreeID = WorktreeID()
    let worktree = Worktree(
      id: worktreeID,
      name: name,
      path: canonicalizedPath,
      branch: branch,
      tabs: [],
      selectedTabID: nil
    )
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees.append(worktree)
    catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID = worktreeID
    store.scheduleSave(catalog)
    return worktreeID
  }

  func removeWorktree(
    _ id: WorktreeID,
    from projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    guard
      let worktreeIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Worktree \(id)")
    }

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    for pane in worktree.tabs.flatMap({ $0.panes }) {
      runtime.closeSurface(for: pane.id)
    }

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees.remove(at: worktreeIndex)
    if catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID == id {
      catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID =
        catalog.spaces[spaceIndex].projects[projectIndex].worktrees.first?.id
    }
    store.scheduleSave(catalog)
  }

  func selectWorktree(_ id: WorktreeID?, in projectID: ProjectID, in spaceID: SpaceID) throws {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    catalog.spaces[spaceIndex].projects[projectIndex].selectedWorktreeID = id
    store.scheduleSave(catalog)
  }

  /// Sets the archived flag on a Worktree (spec W-Q1, soft-hide). The
  /// main checkout (path == project.rootPath) cannot be archived and
  /// throws `.invariantViolation`. Archiving `true` iterates the
  /// Worktree's Panes and calls `runtime.closeSurface(for:)` each so
  /// terminal surfaces are torn down; the on-disk directory and git
  /// refs are NOT touched. Idempotent: unchanged value is a silent
  /// no-op (no save scheduled). Silent no-op when the id is unknown.
  func setWorktreeArchived(worktreeID: WorktreeID, archived: Bool) throws {
    for spaceIndex in catalog.spaces.indices {
      for projectIndex in catalog.spaces[spaceIndex].projects.indices {
        let project = catalog.spaces[spaceIndex].projects[projectIndex]
        guard let worktreeIndex = project.worktrees.firstIndex(where: { $0.id == worktreeID })
        else { continue }
        let worktree = project.worktrees[worktreeIndex]
        if worktree.path == project.rootPath {
          throw HierarchyError.invariantViolation("Cannot archive main checkout")
        }
        guard worktree.archived != archived else { return }
        if archived {
          for pane in worktree.tabs.flatMap({ $0.panes }) {
            runtime.closeSurface(for: pane.id)
          }
        }
        catalog.spaces[spaceIndex].projects[projectIndex]
          .worktrees[worktreeIndex].archived = archived
        store.scheduleSave(catalog)
        return
      }
    }
  }

  /// Flips the Worktree's pinned flag. Pinned rows render in a dedicated section at the
  /// top of the project's row group so the user's "current work" set stays visible even
  /// as the Worktree list grows. Silent no-op for unchanged values and for unknown ids.
  /// Persists via the standard debounced save pipeline.
  func setWorktreePinned(worktreeID: WorktreeID, isPinned: Bool) {
    for spaceIndex in catalog.spaces.indices {
      for projectIndex in catalog.spaces[spaceIndex].projects.indices {
        let project = catalog.spaces[spaceIndex].projects[projectIndex]
        guard let worktreeIndex = project.worktrees.firstIndex(where: { $0.id == worktreeID })
        else { continue }
        guard project.worktrees[worktreeIndex].isPinned != isPinned else { return }
        catalog.spaces[spaceIndex].projects[projectIndex]
          .worktrees[worktreeIndex].isPinned = isPinned
        store.scheduleSave(catalog)
        return
      }
    }
  }

  /// Merges worktrees discovered on disk (typically from
  /// `wt ls --json`) into the catalog. Path-canonicalized dedupe
  /// against existing rows — both sides go through
  /// `URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`
  /// so `/var/...` vs. `/private/var/...` don't cause duplicate rows
  /// against T-PROJECT's `Project.rootPath` which is stored in the
  /// symlink-resolved form. Never removes or mutates existing rows —
  /// stale rows are surfaced in the view layer and only deleted by the
  /// user-initiated Prune action. Idempotent across repeated calls
  /// with the same entries. Returns the count of appended rows so the
  /// caller can surface a toast.
  ///
  /// - Parameters:
  ///   - projectID: target Project.
  ///   - spaceID: parent Space.
  ///   - entries: on-disk worktree metadata (path, branch) from
  ///     `GitWorktreeClient.lsWorktrees`.
  @discardableResult
  func reconcileDiscoveredWorktrees(
    projectID: ProjectID,
    inSpace spaceID: SpaceID,
    entries: [(path: String, branch: String?)]
  ) -> Int {
    guard
      let (spaceIndex, projectIndex) = findProjectIndices(
        projectID: projectID, spaceID: spaceID
      )
    else { return 0 }
    let project = catalog.spaces[spaceIndex].projects[projectIndex]
    let existingPaths = Set(
      project.worktrees.map { Self.canonicalPath($0.path) }
    )
    var appended = 0
    for entry in entries {
      let canonical = Self.canonicalPath(entry.path)
      guard !existingPaths.contains(canonical) else { continue }
      let name =
        (entry.branch?.isEmpty == false)
        ? entry.branch!
        : (canonical as NSString).lastPathComponent
      let worktree = Worktree(
        id: WorktreeID(),
        name: name,
        path: canonical,
        branch: entry.branch,
        tabs: [],
        selectedTabID: nil
      )
      catalog.spaces[spaceIndex].projects[projectIndex].worktrees.append(worktree)
      appended += 1
    }
    if appended > 0 {
      store.scheduleSave(catalog)
    }
    return appended
  }

  /// **Single** canonical form used across the hierarchy layer:
  /// - reconcile dedupe (`reconcileDiscoveredWorktrees`),
  /// - duplicate-path join (`isPathRegistered`),
  /// - catalog storage for `Project.rootPath` and `Worktree.path`.
  ///
  /// Resolves symlinks first, then standardizes (strips trailing
  /// slashes and `.` / `..` components). On macOS, symlink resolution
  /// maps `/var/...` to `/private/var/...` (and similar for `/tmp`,
  /// `/etc`); without this step a `wt ls --json` entry reported as
  /// `/var/folders/...` would fail to match a `Project.rootPath`
  /// stored as `/private/var/folders/...` and the main checkout would
  /// duplicate on every reconcile.
  ///
  /// **Regression guard**: do NOT add a second equivalent helper on
  /// this type. Prior to PR #31 review, two static methods
  /// (`canonical` + `canonicalPath`) coexisted with identical bodies;
  /// any drift (e.g. one side adding trimming) would silently break
  /// the symmetry the PR body guarantees. Route all call-sites
  /// through this function.
  static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
  }

  /// Tears down every terminal surface attached to the Worktree without
  /// mutating the catalog. Used by force-remove so any held file handles
  /// are released before `git worktree remove --force` runs; the catalog
  /// row is dropped afterwards via `removeWorktree`. Silent no-op when
  /// the id is unknown. Idempotent.
  func tearDownWorktreeSurfaces(worktreeID: WorktreeID) {
    for space in catalog.spaces {
      for project in space.projects {
        guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
        else { continue }
        for pane in worktree.tabs.flatMap({ $0.panes }) {
          runtime.closeSurface(for: pane.id)
          runningPanes.remove(pane.id)
        }
        for tab in worktree.tabs {
          lastFocusedPaneByTab.removeValue(forKey: tab.id)
        }
        return
      }
    }
  }

  /// Counts the number of Panes in this Worktree whose terminal surface
  /// is live. Used by force-remove to size the confirmation copy
  /// ("This will terminate N running processes"). 0 when the id is unknown.
  func runningPaneCount(worktreeID: WorktreeID) -> Int {
    for space in catalog.spaces {
      for project in space.projects {
        guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
        else { continue }
        return worktree.tabs
          .flatMap { $0.panes }
          .filter { runtime.hasSurface(for: $0.id) }
          .count
      }
    }
    return 0
  }

  /// Records whether the right-side Git Viewer overlay is visible for this
  /// Worktree. Visibility persists across Space switches and app restarts —
  /// each Worktree remembers its own. Missing `worktreeID` is a silent no-op;
  /// unchanged value is a silent no-op (no save scheduled). Persists via the
  /// standard debounced `store.scheduleSave(catalog)` pipeline. The
  /// `(projectID, spaceID)` arguments are not required — the method scans
  /// all Worktrees in the catalog so the caller does not have to thread
  /// parent IDs through the UI-toggle path.
  func setWorktreeGitViewerVisible(worktreeID: WorktreeID, visible: Bool) {
    for spaceIndex in catalog.spaces.indices {
      for projectIndex in catalog.spaces[spaceIndex].projects.indices {
        guard
          let worktreeIndex = catalog.spaces[spaceIndex].projects[projectIndex]
            .worktrees.firstIndex(where: { $0.id == worktreeID })
        else { continue }
        guard
          catalog.spaces[spaceIndex].projects[projectIndex]
            .worktrees[worktreeIndex].gitViewerVisible != visible
        else { return }
        catalog.spaces[spaceIndex].projects[projectIndex]
          .worktrees[worktreeIndex].gitViewerVisible = visible
        store.scheduleSave(catalog)
        return
      }
    }
  }

  // MARK: - Tab mutations

  func createTab(
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    name: String?
  ) throws -> TabID {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    let tabID = TabID()
    let tab = Tab(id: tabID, name: name, splitTree: SplitTree(), panes: [])
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.append(tab)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID = tabID
    store.scheduleSave(catalog)
    return tabID
  }

  func closeTab(
    _ id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == id
      })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }

    let tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    for pane in tab.panes {
      runtime.closeSurface(for: pane.id)
      runningPanes.remove(pane.id)
    }
    lastFocusedPaneByTab.removeValue(forKey: id)

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.remove(at: tabIndex)
    if catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID == id {
      catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID =
        catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.first?.id
    }
    store.scheduleSave(catalog)
  }

  func selectTab(
    _ id: TabID?,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].selectedTabID = id
    store.scheduleSave(catalog)

    // Focus the last-used pane in the target tab; fall back to the
    // leftmost leaf of the split tree when no memory exists or the
    // remembered pane has since been closed. Silent no-op when there is
    // no active tab or the tab has no panes.
    guard
      let tabID = id,
      let tab = catalog.spaces[spaceIndex].projects[projectIndex]
        .worktrees[worktreeIndex].tabs.first(where: { $0.id == tabID })
    else { return }
    let flatPaneIDs = Set(tab.panes.map(\.id))
    let remembered = lastFocusedPaneByTab[tabID].flatMap { flatPaneIDs.contains($0) ? $0 : nil }
    if let focusID = remembered ?? tab.splitTree.leaves().first {
      runtime.focusSurfaceView(for: focusID)
    }
  }

  // MARK: - Tab mutations (tab-bar uplift)

  /// Renames a Tab in place. `nil` clears the custom name so the UI falls
  /// back to the default "Tab" label. Unchanged value is a silent no-op
  /// (no save scheduled) so repeated calls are free.
  func renameTab(
    _ id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    name: String?
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }
    guard
      catalog.spaces[spaceIndex].projects[projectIndex]
        .worktrees[worktreeIndex].tabs[tabIndex].name != name
    else { return }
    catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex].name = name
    store.scheduleSave(catalog)
  }

  /// Replaces the Worktree's tab ordering in a single atomic write. The
  /// incoming id set must match the current set exactly — mismatched input
  /// throws `.invariantViolation` so upstream drag bugs surface immediately
  /// instead of silently discarding tabs. Same-order input is a silent
  /// no-op.
  func reorderTabs(
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    orderedIDs: [TabID]
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let existing = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs
    let currentIDs = existing.map(\.id)
    guard Set(currentIDs) == Set(orderedIDs) else {
      throw HierarchyError.invariantViolation("tab reorder set mismatch")
    }
    guard currentIDs != orderedIDs else { return }
    let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    let reordered = orderedIDs.compactMap { byID[$0] }
    catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs = reordered
    store.scheduleSave(catalog)
  }

  /// Closes every Tab in the Worktree except `id`. Reuses `closeTab` per
  /// sibling so runtime surfaces are torn down the same way they are for
  /// the single-close path. The pivot is re-selected at the end in case the
  /// per-close auto-advance moved selection elsewhere during teardown.
  func closeOtherTabs(
    keeping id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let siblingIDs = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs
      .map(\.id)
      .filter { $0 != id }
    for siblingID in siblingIDs {
      try? closeTab(siblingID, in: worktreeID, in: projectID, in: spaceID)
    }
    catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].selectedTabID = id
    store.scheduleSave(catalog)
  }

  /// Closes every Tab whose position is strictly after `id`'s. Reuses
  /// `closeTab` per sibling for the same runtime-teardown reasoning as
  /// `closeOtherTabs`. No-op when `id` is the last tab.
  func closeTabsToRight(
    of id: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let pivotIndex = catalog.spaces[spaceIndex].projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == id })
    else {
      throw HierarchyError.notFound("Tab \(id)")
    }
    let doomedIDs = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs
      .suffix(from: pivotIndex + 1)
      .map(\.id)
    for doomedID in doomedIDs {
      try? closeTab(doomedID, in: worktreeID, in: projectID, in: spaceID)
    }
    // Mirror `closeOtherTabs`: if the user's active tab was inside the
    // doomed suffix, `closeTab`'s auto-advance lands on `tabs.first`, not
    // the pivot. Reseat selection so the pivot stays the user's anchor.
    catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].selectedTabID = id
    store.scheduleSave(catalog)
  }

  /// Closes every Tab in the Worktree.
  func closeAllTabs(
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let allIDs = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs.map(\.id)
    for tabID in allIDs {
      try? closeTab(tabID, in: worktreeID, in: projectID, in: spaceID)
    }
  }

  /// Selects the tab before / after the current selection, wrapping at the
  /// ends. Returns the newly selected id, or `nil` when the Worktree has no
  /// tabs. If no tab is currently selected the jump is relative to the
  /// first tab (so `.previous` lands on the last, `.next` on the second).
  @discardableResult
  func selectAdjacentTab(
    direction: TabAdjacency,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws -> TabID? {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    let tabs = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs
    guard !tabs.isEmpty else { return nil }
    let currentID = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].selectedTabID
    let currentIndex = currentID.flatMap { id in
      tabs.firstIndex(where: { $0.id == id })
    } ?? 0
    let count = tabs.count
    let newIndex: Int
    switch direction {
    case .previous:
      newIndex = (currentIndex - 1 + count) % count
    case .next:
      newIndex = (currentIndex + 1) % count
    }
    let newID = tabs[newIndex].id
    // Route through `selectTab` rather than writing `selectedTabID`
    // directly so the M3 focus-restoration block fires for the keyboard
    // shortcut path. Otherwise `⌘⇧[` / `⌘⇧]` would persist the new
    // selection without ever asking AppKit to focus the remembered pane.
    try selectTab(newID, in: worktreeID, in: projectID, in: spaceID)
    return newID
  }

  // MARK: - Runtime state (tab-bar uplift)

  /// Records `paneID` as the tab's last-focused pane so a future
  /// `selectTab` call can restore it. `nil` clears the entry. No catalog
  /// mutation — the map is runtime-only.
  func setLastFocusedPane(_ paneID: PaneID?, in tabID: TabID) {
    if let paneID {
      lastFocusedPaneByTab[tabID] = paneID
    } else {
      lastFocusedPaneByTab.removeValue(forKey: tabID)
    }
  }

  /// Returns the last-focused pane for `tabID`, or `nil` if none was
  /// recorded or the remembered pane has since been closed.
  func lastFocusedPane(in tabID: TabID) -> PaneID? {
    lastFocusedPaneByTab[tabID]
  }

  /// Marks `paneID` as running a tracked command. No caller wired today
  /// — lands with C3 hooks. Idempotent.
  func markPaneRunning(_ paneID: PaneID) {
    runningPanes.insert(paneID)
  }

  /// Clears `paneID`'s running flag. Idempotent.
  func markPaneIdle(_ paneID: PaneID) {
    runningPanes.remove(paneID)
  }

  /// True when any pane inside `tabID` is currently marked running.
  /// Reads a runtime set, never touches the catalog.
  func tabIsDirty(_ tabID: TabID) -> Bool {
    // Fast-path: no pane is running anywhere in the app, so the catalog
    // walk is pointless. Until the C3 hooks plan starts populating
    // `runningPanes`, this short-circuit means the chip's per-render
    // call is a single set-emptiness check rather than a hierarchy walk.
    guard !runningPanes.isEmpty else { return false }
    // Walk the catalog once to locate the tab; absent tabs read as idle.
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          guard let tab = worktree.tabs.first(where: { $0.id == tabID })
          else { continue }
          return tab.panes.contains { runningPanes.contains($0.id) }
        }
      }
    }
    return false
  }

  // MARK: - Pane mutations

  func openPane(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    workingDirectory: String,
    initialCommand: String?,
    env: [String: String] = [:]
  ) throws -> PaneID {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    let paneID = PaneID()
    let pane = Pane(id: paneID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    if tab.splitTree.isEmpty {
      tab.splitTree = SplitTree(leaf: paneID)
    } else {
      let leaves = tab.splitTree.leaves()
      guard let anchor = leaves.first else {
        throw HierarchyError.invariantViolation("Tab has split tree but no leaves")
      }
      tab.splitTree = try tab.splitTree.inserting(paneID, at: anchor, direction: .right)
    }

    tab.panes.append(pane)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: pane, in: worktree, env: env)

    store.scheduleSave(catalog)
    return paneID
  }

  func splitPane(
    _ paneID: PaneID,
    direction: SplitTree<PaneID>.NewDirection,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    workingDirectory: String,
    initialCommand: String?,
    env: [String: String] = [:]
  ) throws -> PaneID {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    let newPaneID = PaneID()
    let newPane = Pane(id: newPaneID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    tab.splitTree = try tab.splitTree.inserting(newPaneID, at: paneID, direction: direction)
    tab.panes.append(newPane)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: newPane, in: worktree, env: env)

    store.scheduleSave(catalog)
    return newPaneID
  }

  func closePane(
    _ paneID: PaneID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    guard let paneIndex = tab.panes.firstIndex(where: { $0.id == paneID }) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }

    runtime.closeSurface(for: paneID)
    runningPanes.remove(paneID)
    if lastFocusedPaneByTab[tabID] == paneID {
      lastFocusedPaneByTab.removeValue(forKey: tabID)
    }

    tab.panes.remove(at: paneIndex)
    tab.splitTree = tab.splitTree.removing(paneID)

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    store.scheduleSave(catalog)
  }

  /// Make the surface view for `paneID` the first responder of its
  /// window. Distinct from `focusPane` (which flips the Tab's zoom
  /// flag) — this only touches AppKit responder-chain focus so keyboard
  /// input routes correctly. Silent no-op when the surface or window
  /// isn't available.
  func focusSurfaceView(for paneID: PaneID) {
    runtime.focusSurfaceView(for: paneID)
  }

  func focusPane(
    _ paneID: PaneID,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    guard tab.panes.contains(where: { $0.id == paneID }) else {
      throw HierarchyError.notFound("Pane \(paneID)")
    }

    tab.splitTree = tab.splitTree.settingZoomed(paneID)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab
    // Remember this pane as the tab's last-focused so the next `selectTab`
    // call restores it instead of snapping to the leftmost leaf.
    lastFocusedPaneByTab[tabID] = paneID

    store.scheduleSave(catalog)
  }

  func unfocusPane(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    tab.splitTree = tab.splitTree.settingZoomed(nil)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  func resizeSplit(
    at path: SplitTree<PaneID>.Path,
    ratio: Double,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }

    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.firstIndex(where: {
        $0.id == tabID
      })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }

    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
    tab.splitTree = try tab.splitTree.resizing(at: path, ratio: ratio)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  // MARK: - Pane address resolution (0008 M5)

  /// Resolves a `PaneID` to the full hierarchy address that owns it. Used by
  /// `PaneActionRouterFeature` to service pane-scoped intents (closeTab,
  /// moveTab, activateTab, equalizeTabSplits). Linear in total pane count —
  /// acceptable at the cardinalities we support; no secondary index needed
  /// yet. `nil` when the pane is unknown (closed mid-flight, stale callback).
  func addressOf(paneID: PaneID) -> (SpaceID, ProjectID, WorktreeID, TabID)? {
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
            return (space.id, project.id, worktree.id, tab.id)
          }
        }
      }
    }
    return nil
  }

  // MARK: - Tab reordering (0008 M5)

  /// Moves a Tab inside its Worktree by `offset` positions. Positive shifts
  /// right, negative shifts left; the final index is clamped to the Worktree's
  /// tab-array bounds so the caller does not need to know the array length.
  /// Zero offset or clamped-to-identity is a silent no-op (no save scheduled).
  /// Persists via the standard debounced `store.scheduleSave` pipeline.
  func moveTab(
    _ tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    offset: Int
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    let count = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs.count
    // Ghostty's move_tab wraps cyclically: moving the last tab forward
    // places it first, moving the first backward places it last. Swift's
    // `%` on negative dividends returns a negative remainder, so pre-add
    // a multiple of `count` to land in [0, count).
    guard count > 0 else { return }
    let normalized = ((tabIndex + offset) % count + count) % count
    let target = normalized
    guard target != tabIndex else { return }
    let tab = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs.remove(at: tabIndex)
    catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs.insert(tab, at: target)
    store.scheduleSave(catalog)
  }

  // MARK: - Split equalization (0008 M5)

  /// Sets every split node's `ratio` inside the Tab's `SplitTree` to 0.5 so
  /// sibling panes render at equal sizes. Leaf-only trees are a silent
  /// no-op. Persists. The concept of a "weight=1 layout" in the design doc
  /// maps onto this ratio — touch-code's tree only carries per-split ratios,
  /// not per-leaf weights, so every balanced split is ratio == 0.5.
  func equalizeTabSplits(
    _ tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID
  ) throws {
    guard
      let (spaceIndex, projectIndex, worktreeIndex) = findWorktreeIndices(
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    else {
      throw HierarchyError.notFound("Worktree \(worktreeID)")
    }
    guard
      let tabIndex = catalog.spaces[spaceIndex].projects[projectIndex]
        .worktrees[worktreeIndex].tabs.firstIndex(where: { $0.id == tabID })
    else {
      throw HierarchyError.notFound("Tab \(tabID)")
    }
    var tab = catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex]
    guard let root = tab.splitTree.root else { return }
    let balanced = Self.balancingRatios(in: root)
    tab.splitTree = SplitTree(root: balanced, zoomed: tab.splitTree.zoomed)
    catalog.spaces[spaceIndex].projects[projectIndex]
      .worktrees[worktreeIndex].tabs[tabIndex] = tab
    store.scheduleSave(catalog)
  }

  private static func balancingRatios(
    in node: SplitTree<PaneID>.Node
  ) -> SplitTree<PaneID>.Node {
    switch node {
    case .leaf:
      return node
    case .split(let split):
      return .split(
        SplitTree<PaneID>.Split(
          direction: split.direction,
          ratio: 0.5,
          left: balancingRatios(in: split.left),
          right: balancingRatios(in: split.right)
        )
      )
    }
  }

  // MARK: - Pane resize (0008 M5)

  /// Adjusts the ratio of the closest ancestor split whose orientation
  /// matches `direction`. The ghostty RESIZE_SPLIT action carries a pixel
  /// amount (default keybinds are e.g. 10–20 px), but touch-code's split
  /// tree only stores ratios in `[0.1, 0.9]`. Adding the raw pixel value
  /// to a ratio collapses the split on the first keypress, so we scale
  /// the delta by `pixelsPerRatioStep` — an empirical divisor that maps
  /// a default 10 px keybind to a ~2.5% ratio nudge on a typical 400 px
  /// split. The viewport layer will later expose the real split frame
  /// via `ResizePaneOptions` so the divisor can become per-split.
  ///
  /// Direction semantics (matches ghostty's FocusDirection analog):
  /// - `.left`: grow the left child  → decrease ratio of nearest horizontal split
  /// - `.right`: grow the right child → increase ratio of nearest horizontal split
  /// - `.up`: grow the top child     → decrease ratio of nearest vertical split
  /// - `.down`: grow the bottom child → increase ratio of nearest vertical split
  ///
  /// Silent no-op when the pane is unknown or no ancestor split matches the
  /// direction (e.g. resize-left on a purely vertical column).
  func resizePane(_ paneID: PaneID, direction: ResizeDirection, amount: Double) throws {
    // Empirical px → ratio scale. See doc above.
    let pixelsPerRatioStep: Double = 400
    let ratioDelta = amount / pixelsPerRatioStep
    for spaceIndex in catalog.spaces.indices {
      for projectIndex in catalog.spaces[spaceIndex].projects.indices {
        for worktreeIndex in catalog.spaces[spaceIndex].projects[projectIndex].worktrees.indices {
          let worktree = catalog.spaces[spaceIndex].projects[projectIndex]
            .worktrees[worktreeIndex]
          for tabIndex in worktree.tabs.indices
          where worktree.tabs[tabIndex].splitTree.contains(paneID) {
            var tab = worktree.tabs[tabIndex]
            guard let leafPath = tab.splitTree.path(to: paneID) else { return }
            let orientation: SplitTree<PaneID>.Direction =
              (direction == .left || direction == .right)
              ? .horizontal : .vertical
            guard
              let (ancestorPath, currentRatio, grewRight) = Self.findAncestorSplit(
                root: tab.splitTree.root,
                leafPath: leafPath,
                orientation: orientation
              )
            else { return }
            let grow: Bool = (direction == .right || direction == .down)
            let signedDelta = (grewRight == grow) ? ratioDelta : -ratioDelta
            let newRatio = currentRatio + signedDelta
            tab.splitTree = try tab.splitTree.resizing(at: ancestorPath, ratio: newRatio)
            catalog.spaces[spaceIndex].projects[projectIndex]
              .worktrees[worktreeIndex].tabs[tabIndex] = tab
            store.scheduleSave(catalog)
            return
          }
        }
      }
    }
  }

  /// Walks up from `leafPath` toward the root and returns the nearest split
  /// whose orientation matches. `grewRight` is `true` when the leaf lives
  /// under the split's right child (so growing its side is `ratio += delta`).
  private static func findAncestorSplit(
    root: SplitTree<PaneID>.Node?,
    leafPath: SplitTree<PaneID>.Path,
    orientation: SplitTree<PaneID>.Direction
  ) -> (SplitTree<PaneID>.Path, Double, Bool)? {
    guard let root else { return nil }
    var components = leafPath.components
    while !components.isEmpty {
      let childBranch = components.removeLast()
      let ancestorPath = SplitTree<PaneID>.Path(components)
      guard case .split(let split) = root.node(at: ancestorPath),
        split.direction == orientation
      else { continue }
      return (ancestorPath, split.ratio, childBranch == .right)
    }
    return nil
  }

  // MARK: - Space activation (M6)

  /// Select a Space as the catalog's active one. `tc space activate` in M6
  /// drives this; the Mac app UI ties to the same field.
  func activateSpace(_ id: SpaceID) throws {
    guard catalog.spaces.contains(where: { $0.id == id }) else {
      throw HierarchyError.notFound("Space \(id)")
    }
    catalog.selectedSpaceID = id
    store.scheduleSave(catalog)
  }

  // MARK: - Worktree / Tab activation (M6)

  func activateWorktree(_ id: WorktreeID) throws {
    for (si, space) in catalog.spaces.enumerated() {
      for (pi, project) in space.projects.enumerated() where project.worktrees.contains(where: { $0.id == id }) {
        catalog.spaces[si].projects[pi].selectedWorktreeID = id
        store.scheduleSave(catalog)
        return
      }
    }
    throw HierarchyError.notFound("Worktree \(id)")
  }

  func activateTab(_ id: TabID) throws {
    for (si, space) in catalog.spaces.enumerated() {
      for (pi, project) in space.projects.enumerated() {
        for (wi, worktree) in project.worktrees.enumerated() where worktree.tabs.contains(where: { $0.id == id }) {
          catalog.spaces[si].projects[pi].worktrees[wi].selectedTabID = id
          store.scheduleSave(catalog)
          return
        }
      }
    }
    throw HierarchyError.notFound("Tab \(id)")
  }

  // MARK: - Pane labels (canonical writer for C3 / C4)

  /// Update a Pane's `labels` set. **Single canonical writer** — every
  /// user-facing write path (the CLI's `tc pane label`, the hook action
  /// DSL's `HookAction.setPaneLabels`, any future UI) routes through this
  /// method. Keeps label mutations auditable and persists through the same
  /// `CatalogStore.scheduleSave` every other mutation uses.
  ///
  /// - Parameters:
  ///   - paneID: target Pane.
  ///   - labels: labels to apply.
  ///   - replace: when `true`, replaces the set entirely; when `false`,
  ///     union-merges with the existing set.
  /// - Throws: `HierarchyError.notFound` if the Pane id is unknown.
  func setPaneLabels(
    _ paneID: PaneID,
    labels: Set<String>,
    replace: Bool = false
  ) throws {
    for spaceIndex in catalog.spaces.indices {
      for projectIndex in catalog.spaces[spaceIndex].projects.indices {
        for worktreeIndex in catalog.spaces[spaceIndex].projects[projectIndex].worktrees.indices {
          for tabIndex in catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.indices {
            let panes = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
              .panes
            if let paneIndex = panes.firstIndex(where: { $0.id == paneID }) {
              var pane = panes[paneIndex]
              pane.labels = replace ? labels : pane.labels.union(labels)
              catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex].panes[
                paneIndex] = pane
              store.scheduleSave(catalog)
              return
            }
          }
        }
      }
    }
    throw HierarchyError.notFound("Pane \(paneID)")
  }

  // MARK: - Legacy v1 catalog fields

  /// One-shot drain of the two per-Project preference fields that lived on v1
  /// `catalog.json` (`defaultEditor`, `worktreesDirectory`). Returns the
  /// current values keyed by `ProjectID`, then clears them in-memory so the
  /// next save writes the v2 shape without those keys. Call sequence in
  /// `AppState.init`: run this **before** constructing `SettingsStore` so the
  /// drained map can be folded into `Settings.projects[pid]` during the v2 →
  /// v3 `settings.json` migration via the injected `catalogOverrides` closure.
  ///
  /// Idempotent: a second call on an already-drained catalog returns an
  /// empty map and schedules no save. Any Project whose two fields are both
  /// nil is omitted from the returned map.
  func drainLegacyOverrides() -> [ProjectID: (defaultEditor: EditorID?, worktreesDirectory: String?)] {
    var overrides: [ProjectID: (defaultEditor: EditorID?, worktreesDirectory: String?)] = [:]
    var mutated = false
    for sIdx in catalog.spaces.indices {
      for pIdx in catalog.spaces[sIdx].projects.indices {
        let editor = catalog.spaces[sIdx].projects[pIdx].defaultEditor
        let wtDir = catalog.spaces[sIdx].projects[pIdx].worktreesDirectory
        guard editor != nil || wtDir != nil else { continue }
        let pid = catalog.spaces[sIdx].projects[pIdx].id
        overrides[pid] = (defaultEditor: editor, worktreesDirectory: wtDir)
        catalog.spaces[sIdx].projects[pIdx].defaultEditor = nil
        catalog.spaces[sIdx].projects[pIdx].worktreesDirectory = nil
        mutated = true
      }
    }
    if mutated {
      store.scheduleSave(catalog)
    }
    return overrides
  }

  // MARK: - Phase 2: env resolution

  /// Resolves the merged environment for a Project's spawned subprocesses.
  /// Combines `ProcessInfo.processInfo.environment` with
  /// `Settings.projects[pid].envVars`; project-defined keys win on collision.
  /// Pure / nonisolated so M8 (PaneSurface env injection) and M9 (lifecycle
  /// script execution) can call it from off the main actor when convenient.
  nonisolated static func resolvedEnv(
    for projectID: ProjectID,
    in settings: Settings
  ) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    // Strip terminal-describing variables inherited from the parent process so
    // libghostty's own PTY-spawn TERM injection (`xterm-ghostty`) is what the
    // child shell sees. When touch-code.app is launched from a non-interactive
    // context (e.g. `make` → `open`, an IDE compile shell) parent `TERM=dumb`
    // would otherwise flow through `ghostty_surface_config.env_vars` and
    // override ghostty's value, breaking starship and other TUIs.
    for key in Self.inheritedTerminalEnvVarsToStrip {
      env.removeValue(forKey: key)
    }
    if let overrides = settings.projects[projectID]?.envVars {
      for (key, value) in overrides {
        env[key] = value
      }
    }
    return env
  }

  nonisolated private static let inheritedTerminalEnvVarsToStrip: [String] = [
    "TERM", "TERMCAP", "TERMINFO", "COLORTERM",
  ]

  // MARK: - Helpers

  private func findProjectIndices(projectID: ProjectID, spaceID: SpaceID) -> (Int, Int)? {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == projectID }) else {
      return nil
    }
    return (spaceIndex, projectIndex)
  }

  private func findWorktreeIndices(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID
  ) -> (Int, Int, Int)? {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == projectID }) else {
      return nil
    }
    guard
      let worktreeIndex = catalog.spaces[spaceIndex].projects[projectIndex].worktrees.firstIndex(where: {
        $0.id == worktreeID
      })
    else { return nil }
    return (spaceIndex, projectIndex, worktreeIndex)
  }
}
