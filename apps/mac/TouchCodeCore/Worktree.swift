import Foundation

public nonisolated struct Worktree: Equatable, Codable, Sendable, Identifiable {
  public var id: WorktreeID
  public var name: String
  public var path: String
  public var branch: String?
  public var tabs: [Tab]
  public var selectedTabID: TabID?

  public init(
    id: WorktreeID = WorktreeID(),
    name: String,
    path: String,
    branch: String? = nil,
    tabs: [Tab] = [],
    selectedTabID: TabID? = nil
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.branch = branch
    self.tabs = tabs
    self.selectedTabID = selectedTabID
  }
}
