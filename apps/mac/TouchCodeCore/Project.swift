import Foundation

public nonisolated struct Project: Equatable, Codable, Sendable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var rootPath: String
  public var gitRoot: String?
  public var worktreesDirectory: String?
  public var defaultEditor: String?
  public var worktrees: [Worktree]
  public var selectedWorktreeID: WorktreeID?

  public init(
    id: ProjectID = ProjectID(),
    name: String,
    rootPath: String,
    gitRoot: String? = nil,
    worktreesDirectory: String? = nil,
    defaultEditor: String? = nil,
    worktrees: [Worktree] = [],
    selectedWorktreeID: WorktreeID? = nil
  ) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.gitRoot = gitRoot
    self.worktreesDirectory = worktreesDirectory
    self.defaultEditor = defaultEditor
    self.worktrees = worktrees
    self.selectedWorktreeID = selectedWorktreeID
  }

  /// A Project supports Git-backed Worktree operations only when it has a resolved git root.
  /// For non-git Projects, the UI presents a single synthetic Worktree (`Project.rootPath`)
  /// and the "Add Worktree" affordance is suppressed.
  public var supportsWorktrees: Bool { gitRoot != nil }
}
