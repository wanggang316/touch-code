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
  private enum CodingKeys: String, CodingKey { case id, workingDirectory, labels }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(PaneID.self, forKey: .id)
    self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    // initialCommand is a one-shot creation-time input replayed by
    // TerminalEngine.ensureSurface. Persisting it would cause the command to
    // re-run on every app launch when the tab is restored. Decode as nil and
    // ignore any legacy value that older builds may have written.
    self.initialCommand = nil
    self.labels = try container.decodeIfPresent(Set<String>.self, forKey: .labels) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    if !labels.isEmpty { try container.encode(labels.sorted(), forKey: .labels) }
  }
}
