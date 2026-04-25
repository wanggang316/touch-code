import Foundation

/// Placeholder shape for `ProjectSettings.scripts`. Reserves the slot in the
/// v3 `settings.json` schema; the real definition (kinds, colours, icons,
/// execution semantics) lands in a follow-up wave alongside the Scripts
/// sub-pane. Minimal today to keep `ProjectSettings` Codable round-trip
/// stable — round-tripping `[ScriptDefinition]` through current code is
/// enough even though nothing constructs one yet.
public nonisolated struct ScriptDefinition: Equatable, Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  public var command: String

  public init(id: UUID = UUID(), name: String, command: String) {
    self.id = id
    self.name = name
    self.command = command
  }
}
