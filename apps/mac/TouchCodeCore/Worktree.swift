import Foundation

public nonisolated struct Worktree: Equatable, Sendable, Identifiable {
  public var id: WorktreeID
  public var name: String
  public var path: String
  public var branch: String?
  public var tabs: [Tab]
  public var selectedTabID: TabID?
  /// Whether the right-side Git Viewer overlay is visible for this Worktree.
  /// Persists across app restarts; each Worktree remembers its own
  /// visibility. Defaults to `false` — pre-T0 catalogs also decode to
  /// `false` via the Codable `decodeIfPresent` path.
  public var gitViewerVisible: Bool
  /// App-layer soft-hide. `true` removes the Worktree from the main sidebar
  /// list without touching disk or git refs (see the Worktree Management
  /// spec). Defaults to `false`; pre-archive catalogs decode to `false` via
  /// `decodeIfPresent`, and the encode path omits the key when `false` so
  /// existing catalogs round-trip identically.
  public var archived: Bool
  /// User-marked "pinned" state. Pinned Worktrees render in their own section
  /// at the top of the Project's row group (below the main checkout). Defaults
  /// to `false`; pre-pin catalogs decode to `false` via `decodeIfPresent`, and
  /// the encode path omits the key when `false` so existing catalogs round-trip
  /// identically.
  public var isPinned: Bool

  public init(
    id: WorktreeID = WorktreeID(),
    name: String,
    path: String,
    branch: String? = nil,
    tabs: [Tab] = [],
    selectedTabID: TabID? = nil,
    gitViewerVisible: Bool = false,
    archived: Bool = false,
    isPinned: Bool = false
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.branch = branch
    self.tabs = tabs
    self.selectedTabID = selectedTabID
    self.gitViewerVisible = gitViewerVisible
    self.archived = archived
    self.isPinned = isPinned
  }
}

extension Worktree: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, path, branch, tabs, selectedTabID, gitViewerVisible, archived, isPinned
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(WorktreeID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.path = try container.decode(String.self, forKey: .path)
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
    self.selectedTabID = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    self.gitViewerVisible = try container.decodeIfPresent(Bool.self, forKey: .gitViewerVisible) ?? false
    self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(path, forKey: .path)
    try container.encodeIfPresent(branch, forKey: .branch)
    try container.encode(tabs, forKey: .tabs)
    try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
    // Only emit `gitViewerVisible` when it's non-default. Decode path uses
    // `decodeIfPresent ?? false`, so omitting the key for default-visibility
    // Worktrees (the common case) shrinks on-disk catalogs and keeps
    // pre-T0 catalogs round-trip-identical.
    if gitViewerVisible {
      try container.encode(true, forKey: .gitViewerVisible)
    }
    // Same rationale as `gitViewerVisible`: omit when false so pre-archive
    // catalogs round-trip identically.
    if archived {
      try container.encode(true, forKey: .archived)
    }
    if isPinned {
      try container.encode(true, forKey: .isPinned)
    }
  }
}
