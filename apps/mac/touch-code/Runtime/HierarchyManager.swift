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
  /// to Finder. Added in 0005 M6a for C8's UI.
  func setDefaultEditor(_ editorID: EditorID?, for projectID: ProjectID, in spaceID: SpaceID) throws {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    catalog.spaces[spaceIndex].projects[projectIndex].defaultEditor = editorID
    store.scheduleSave(catalog)
  }

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

  /// Per-Project override for the `worktreesDirectory`. `nil` or whitespace
  /// clears the override so the default (`~/.touch-code/repos/<name>/`) takes
  /// effect. Equal-value writes are dropped.
  func setProjectWorktreesDirectory(
    _ path: String?,
    projectID: ProjectID,
    spaceID: SpaceID
  ) throws {
    guard let (spaceIndex, projectIndex) = findProjectIndices(projectID: projectID, spaceID: spaceID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value: String? = (normalized?.isEmpty ?? true) ? nil : normalized
    guard catalog.spaces[spaceIndex].projects[projectIndex].worktreesDirectory != value else { return }
    catalog.spaces[spaceIndex].projects[projectIndex].worktreesDirectory = value
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
    for panel in worktree.tabs.flatMap({ $0.panels }) {
      runtime.closeSurface(for: panel.id)
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
  /// Worktree's Panels and calls `runtime.closeSurface(for:)` each so
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
          for panel in worktree.tabs.flatMap({ $0.panels }) {
            runtime.closeSurface(for: panel.id)
          }
        }
        catalog.spaces[spaceIndex].projects[projectIndex]
          .worktrees[worktreeIndex].archived = archived
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
    guard let (spaceIndex, projectIndex) = findProjectIndices(
      projectID: projectID, spaceID: spaceID
    ) else { return 0 }
    let project = catalog.spaces[spaceIndex].projects[projectIndex]
    let existingPaths = Set(
      project.worktrees.map { Self.canonicalPath($0.path) }
    )
    var appended = 0
    for entry in entries {
      let canonical = Self.canonicalPath(entry.path)
      guard !existingPaths.contains(canonical) else { continue }
      let name = (entry.branch?.isEmpty == false)
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
        for panel in worktree.tabs.flatMap({ $0.panels }) {
          runtime.closeSurface(for: panel.id)
        }
        return
      }
    }
  }

  /// Counts the number of Panels in this Worktree whose terminal surface
  /// is live. Used by force-remove to size the confirmation copy
  /// ("This will terminate N running processes"). 0 when the id is unknown.
  func runningPanelCount(worktreeID: WorktreeID) -> Int {
    for space in catalog.spaces {
      for project in space.projects {
        guard let worktree = project.worktrees.first(where: { $0.id == worktreeID })
        else { continue }
        return worktree.tabs
          .flatMap { $0.panels }
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
    let tab = Tab(id: tabID, name: name, splitTree: SplitTree(), panels: [])
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
    for panel in tab.panels {
      runtime.closeSurface(for: panel.id)
    }

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
  }

  // MARK: - Panel mutations

  func openPanel(
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    workingDirectory: String,
    initialCommand: String?
  ) throws -> PanelID {
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

    let panelID = PanelID()
    let panel = Panel(id: panelID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    if tab.splitTree.isEmpty {
      tab.splitTree = SplitTree(leaf: panelID)
    } else {
      let leaves = tab.splitTree.leaves()
      guard let anchor = leaves.first else {
        throw HierarchyError.invariantViolation("Tab has split tree but no leaves")
      }
      tab.splitTree = try tab.splitTree.inserting(panelID, at: anchor, direction: .right)
    }

    tab.panels.append(panel)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: panel, in: worktree)

    store.scheduleSave(catalog)
    return panelID
  }

  func splitPanel(
    _ panelID: PanelID,
    direction: SplitTree<PanelID>.NewDirection,
    in tabID: TabID,
    in worktreeID: WorktreeID,
    in projectID: ProjectID,
    in spaceID: SpaceID,
    workingDirectory: String,
    initialCommand: String?
  ) throws -> PanelID {
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

    let newPanelID = PanelID()
    let newPanel = Panel(id: newPanelID, workingDirectory: workingDirectory, initialCommand: initialCommand)
    var tab = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]

    tab.splitTree = try tab.splitTree.inserting(newPanelID, at: panelID, direction: direction)
    tab.panels.append(newPanel)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    let worktree = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex]
    try runtime.ensureSurface(for: newPanel, in: worktree)

    store.scheduleSave(catalog)
    return newPanelID
  }

  func closePanel(
    _ panelID: PanelID,
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
    guard let panelIndex = tab.panels.firstIndex(where: { $0.id == panelID }) else {
      throw HierarchyError.notFound("Panel \(panelID)")
    }

    runtime.closeSurface(for: panelID)

    tab.panels.remove(at: panelIndex)
    tab.splitTree = tab.splitTree.removing(panelID)

    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    try tab.validateInvariants()

    store.scheduleSave(catalog)
  }

  func focusPanel(
    _ panelID: PanelID,
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
    guard tab.panels.contains(where: { $0.id == panelID }) else {
      throw HierarchyError.notFound("Panel \(panelID)")
    }

    tab.splitTree = tab.splitTree.settingZoomed(panelID)
    catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex] = tab

    store.scheduleSave(catalog)
  }

  func unfocusPanel(
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
    at path: SplitTree<PanelID>.Path,
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

  // MARK: - Panel labels (canonical writer for C3 / C4)

  /// Update a Panel's `labels` set. **Single canonical writer** — every
  /// user-facing write path (the CLI's `tc panel label`, the hook action
  /// DSL's `HookAction.setPanelLabels`, any future UI) routes through this
  /// method. Keeps label mutations auditable and persists through the same
  /// `CatalogStore.scheduleSave` every other mutation uses.
  ///
  /// - Parameters:
  ///   - panelID: target Panel.
  ///   - labels: labels to apply.
  ///   - replace: when `true`, replaces the set entirely; when `false`,
  ///     union-merges with the existing set.
  /// - Throws: `HierarchyError.notFound` if the Panel id is unknown.
  func setPanelLabels(
    _ panelID: PanelID,
    labels: Set<String>,
    replace: Bool = false
  ) throws {
    for spaceIndex in catalog.spaces.indices {
      for projectIndex in catalog.spaces[spaceIndex].projects.indices {
        for worktreeIndex in catalog.spaces[spaceIndex].projects[projectIndex].worktrees.indices {
          for tabIndex in catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs.indices {
            let panels = catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex]
              .panels
            if let panelIndex = panels.firstIndex(where: { $0.id == panelID }) {
              var panel = panels[panelIndex]
              panel.labels = replace ? labels : panel.labels.union(labels)
              catalog.spaces[spaceIndex].projects[projectIndex].worktrees[worktreeIndex].tabs[tabIndex].panels[
                panelIndex] = panel
              store.scheduleSave(catalog)
              return
            }
          }
        }
      }
    }
    throw HierarchyError.notFound("Panel \(panelID)")
  }

  // MARK: - Project-only mutators (Settings Repository panes)

  /// Sets or clears the per-Project worktree base directory override. `nil`
  /// clears so worktree creation falls back to the global default. Unchanged
  /// value is a silent no-op. `.notFound` when no space owns the Project.
  func setWorktreesDirectory(_ path: String?, for projectID: ProjectID) throws {
    guard let (sIdx, pIdx) = findProjectAnySpace(projectID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    guard catalog.spaces[sIdx].projects[pIdx].worktreesDirectory != path else { return }
    catalog.spaces[sIdx].projects[pIdx].worktreesDirectory = path
    store.scheduleSave(catalog)
  }

  /// Sibling of `setDefaultEditor(_:for:in:)` that takes only a `ProjectID`.
  /// Used by the Settings Repository General pane, which has no `SpaceID` in
  /// scope. `nil` clears. Unchanged value is a silent no-op. `.notFound` when
  /// no space owns the Project.
  func setDefaultEditorAnySpace(_ editorID: EditorID?, for projectID: ProjectID) throws {
    guard let (sIdx, pIdx) = findProjectAnySpace(projectID) else {
      throw HierarchyError.notFound("Project \(projectID)")
    }
    guard catalog.spaces[sIdx].projects[pIdx].defaultEditor != editorID else { return }
    catalog.spaces[sIdx].projects[pIdx].defaultEditor = editorID
    store.scheduleSave(catalog)
  }

  // MARK: - Helpers

  private func findProjectIndices(projectID: ProjectID, spaceID: SpaceID) -> (Int, Int)? {
    guard let spaceIndex = catalog.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
    guard let projectIndex = catalog.spaces[spaceIndex].projects.firstIndex(where: { $0.id == projectID }) else {
      return nil
    }
    return (spaceIndex, projectIndex)
  }

  /// Locates the Project across all Spaces. Returns the first match —
  /// `ProjectID`s are UUIDs so collisions are effectively zero, but in debug
  /// builds assert at most one Space owns the id. Used by the Settings
  /// Repository panes which carry only a `ProjectID`.
  private func findProjectAnySpace(_ projectID: ProjectID) -> (Int, Int)? {
    var found: (Int, Int)?
    for (sIdx, space) in catalog.spaces.enumerated() {
      if let pIdx = space.projects.firstIndex(where: { $0.id == projectID }) {
        assert(found == nil, "Project \(projectID) appears in multiple spaces")
        found = (sIdx, pIdx)
      }
    }
    return found
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
