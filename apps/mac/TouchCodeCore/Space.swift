import Foundation

public nonisolated struct Space: Equatable, Sendable, Identifiable {
  public var id: SpaceID
  public var name: String
  public var projects: [Project]
  public var selectedProjectID: ProjectID?
  /// Worktree to restore when the window re-activates this Space. `nil` falls
  /// back to the Project-scoped `selectedWorktreeID` resolution. T0 leaves
  /// stale-reference pruning (when the referenced Worktree is removed) to
  /// the Space-switcher feature.
  public var lastActiveWorktreeID: WorktreeID?

  public init(
    id: SpaceID = SpaceID(),
    name: String,
    projects: [Project] = [],
    selectedProjectID: ProjectID? = nil,
    lastActiveWorktreeID: WorktreeID? = nil
  ) {
    self.id = id
    self.name = name
    self.projects = projects
    self.selectedProjectID = selectedProjectID
    self.lastActiveWorktreeID = lastActiveWorktreeID
  }
}

extension Space: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, name, projects, selectedProjectID, lastActiveWorktreeID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(SpaceID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
    self.selectedProjectID = try container.decodeIfPresent(ProjectID.self, forKey: .selectedProjectID)
    self.lastActiveWorktreeID = try container.decodeIfPresent(WorktreeID.self, forKey: .lastActiveWorktreeID)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(projects, forKey: .projects)
    try container.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
    try container.encodeIfPresent(lastActiveWorktreeID, forKey: .lastActiveWorktreeID)
  }
}
