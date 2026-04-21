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
    self.loadState = loadState
  }

  /// A Project supports Git-backed Worktree operations only when it has a resolved git root.
  /// For non-git Projects, the UI presents a single synthetic Worktree (`Project.rootPath`)
  /// and the "Add Worktree" affordance is suppressed.
  public var supportsWorktrees: Bool { gitRoot != nil }
}

extension Project: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, rootPath, gitRoot, worktreesDirectory, defaultEditor, worktrees, selectedWorktreeID
    // loadState intentionally omitted — transient.
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(ProjectID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.rootPath = try container.decode(String.self, forKey: .rootPath)
    self.gitRoot = try container.decodeIfPresent(String.self, forKey: .gitRoot)
    self.worktreesDirectory = try container.decodeIfPresent(String.self, forKey: .worktreesDirectory)
    self.defaultEditor = try container.decodeIfPresent(String.self, forKey: .defaultEditor)
    self.worktrees = try container.decodeIfPresent([Worktree].self, forKey: .worktrees) ?? []
    self.selectedWorktreeID = try container.decodeIfPresent(WorktreeID.self, forKey: .selectedWorktreeID)
    self.loadState = .loading
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encodeIfPresent(gitRoot, forKey: .gitRoot)
    try container.encodeIfPresent(worktreesDirectory, forKey: .worktreesDirectory)
    try container.encodeIfPresent(defaultEditor, forKey: .defaultEditor)
    try container.encode(worktrees, forKey: .worktrees)
    try container.encodeIfPresent(selectedWorktreeID, forKey: .selectedWorktreeID)
    // loadState intentionally not encoded.
  }
}
