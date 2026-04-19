import Foundation

public nonisolated struct Panel: Equatable, Codable, Sendable, Identifiable {
  public var id: PanelID
  public var workingDirectory: String
  public var initialCommand: String?

  public init(
    id: PanelID = PanelID(),
    workingDirectory: String,
    initialCommand: String? = nil
  ) {
    self.id = id
    self.workingDirectory = workingDirectory
    self.initialCommand = initialCommand
  }
}
