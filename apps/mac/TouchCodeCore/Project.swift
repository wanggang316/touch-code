import Foundation

/// Per-Project health signal driven at runtime by `ProjectReconciler`.
/// Intentionally **transient** — not encoded into `catalog.json`. Every decode
/// produces `.loading`; the reconciler transitions the value on its first pass
/// after launch (and on window focus / Retry). Keeping this out of `Codable`
/// avoids a catalog-schema bump and keeps pre-existing catalogs round-trip
/// identical.
public nonisolated enum ProjectLoadState: Equatable, Sendable {
  case loading
  case ready
  case failed(reason: String)
}

public nonisolated struct Project: Equatable, Sendable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var rootPath: String
  public var gitRoot: String?
  public var worktreesDirectory: String?
  public var defaultEditor: String?
  public var worktrees: [Worktree]
  public var selectedWorktreeID: WorktreeID?
  /// Sidebar disclosure state for this Project's worktree group. Defaults to
  /// `true` so newly added Projects reveal their worktrees immediately.
  /// Persisted via the standard catalog save pipeline so the open/closed
  /// choice survives app restarts. Pre-existing catalogs without this key
  /// also decode to `true` (preserves "everything visible" baseline).
  public var isExpanded: Bool
  /// User-assigned tag membership. Set semantics in memory; encoded as a
  /// sorted `[TagID]` so `git diff catalog.json` is order-stable. Default
  /// empty — pre-tag catalogs decode to no tags.
  public var tagIDs: Set<TagID>
  /// Transient. See `ProjectLoadState` doc-comment.
  public var loadState: ProjectLoadState

  public init(
    id: ProjectID = ProjectID(),
    name: String,
    rootPath: String,
    gitRoot: String? = nil,
    worktreesDirectory: String? = nil,
    defaultEditor: String? = nil,
    worktrees: [Worktree] = [],
    selectedWorktreeID: WorktreeID? = nil,
    isExpanded: Bool = true,
    tagIDs: Set<TagID> = [],
    loadState: ProjectLoadState = .loading
  ) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.gitRoot = gitRoot
    self.worktreesDirectory = worktreesDirectory
    self.defaultEditor = defaultEditor
    self.worktrees = worktrees
    self.selectedWorktreeID = selectedWorktreeID
    self.isExpanded = isExpanded
    self.tagIDs = tagIDs
    self.loadState = loadState
  }

  /// A Project supports Git-backed Worktree operations only when it has a resolved git root.
  /// For non-git Projects, the UI presents a single synthetic Worktree (`Project.rootPath`)
  /// and the "Add Worktree" affordance is suppressed.
  public var supportsWorktrees: Bool { gitRoot != nil }
}

extension Project: Codable {
  /// On-disk coding keys. `defaultEditor` and `worktreesDirectory` remain decoded from
  /// legacy v1 catalogs so `HierarchyManager.drainLegacyOverrides` can move them to
  /// `Settings.projects[pid]` on first load, but they are **no longer encoded** — v2
  /// Projects never carry those keys. `loadState` is transient.
  private enum CodingKeys: String, CodingKey {
    case id, name, rootPath, gitRoot, worktrees, selectedWorktreeID, isExpanded, tagIDs
    // v1-only (decoded, never encoded): worktreesDirectory, defaultEditor
  }

  /// Legacy v1 keys. Separated from `CodingKeys` so the encoder cannot accidentally
  /// write them — the decoder reads them through a distinct container.
  private enum LegacyV1CodingKeys: String, CodingKey {
    case worktreesDirectory, defaultEditor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(ProjectID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.rootPath = try container.decode(String.self, forKey: .rootPath)
    self.gitRoot = try container.decodeIfPresent(String.self, forKey: .gitRoot)
    self.worktrees = try container.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
    self.selectedWorktreeID = try container.decodeIfPresent(WorktreeID.self, forKey: .selectedWorktreeID)
    // Default true: pre-existing catalogs (no key) and freshly added Projects
    // both render expanded. Encoder only emits the key when collapsed, so
    // round-trips on existing data stay byte-identical.
    self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    let tagIDArray = try container.decodeIfPresent([TagID].self, forKey: .tagIDs) ?? []
    self.tagIDs = Set(tagIDArray)
    self.loadState = .loading

    // Legacy v1 fields — present on v1 catalogs, absent on v2. Carried in-memory so
    // `HierarchyManager.drainLegacyOverrides` can hand them to `SettingsStore`.
    let legacy = try decoder.container(keyedBy: LegacyV1CodingKeys.self)
    self.worktreesDirectory = try legacy.decodeIfPresent(String.self, forKey: .worktreesDirectory)
    self.defaultEditor = try legacy.decodeIfPresent(String.self, forKey: .defaultEditor)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encodeIfPresent(gitRoot, forKey: .gitRoot)
    try container.encode(worktrees, forKey: .worktrees)
    try container.encodeIfPresent(selectedWorktreeID, forKey: .selectedWorktreeID)
    // Symmetric with `Worktree.isPinned` / `gitViewerVisible`: only emit when
    // the value diverges from the decode-time default (`true`). Keeps catalogs
    // round-trip identical for Projects in the default expanded state.
    if !isExpanded {
      try container.encode(false, forKey: .isExpanded)
    }
    // Stable on-disk ordering for set-typed memory: sort by raw UUID string.
    // Omit the key entirely when the project carries no tags so pre-tag
    // catalogs round-trip byte-identical.
    if !tagIDs.isEmpty {
      let sorted = tagIDs.sorted { $0.raw.uuidString < $1.raw.uuidString }
      try container.encode(sorted, forKey: .tagIDs)
    }
    // `defaultEditor` and `worktreesDirectory` intentionally not encoded (v2 shape).
    // `loadState` intentionally not encoded.
  }
}
