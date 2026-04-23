import Foundation

public nonisolated struct Pane: Equatable, Sendable, Identifiable {
  public var id: PaneID
  public var workingDirectory: String
  public var initialCommand: String?
  public var labels: Set<String>

  public init(
    id: PaneID = PaneID(),
    workingDirectory: String,
    initialCommand: String? = nil,
    labels: Set<String> = []
  ) {
    self.id = id
    self.workingDirectory = workingDirectory
    self.initialCommand = initialCommand
    self.labels = labels
  }
}

extension Pane: Codable {
  private enum CodingKeys: String, CodingKey { case id, workingDirectory, initialCommand, labels }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(PaneID.self, forKey: .id)
    self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    self.initialCommand = try container.decodeIfPresent(String.self, forKey: .initialCommand)
    self.labels = try container.decodeIfPresent(Set<String>.self, forKey: .labels) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    try container.encodeIfPresent(initialCommand, forKey: .initialCommand)
    if !labels.isEmpty { try container.encode(labels.sorted(), forKey: .labels) }
  }
}
