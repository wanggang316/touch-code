import Foundation

public nonisolated struct Space: Equatable, Codable, Sendable, Identifiable {
  public var id: SpaceID
  public var name: String
  public var projects: [Project]
  public var selectedProjectID: ProjectID?

  public init(
    id: SpaceID = SpaceID(),
    name: String,
    projects: [Project] = [],
    selectedProjectID: ProjectID? = nil
  ) {
    self.id = id
    self.name = name
    self.projects = projects
    self.selectedProjectID = selectedProjectID
  }
}
