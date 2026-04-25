import Foundation

/// User-defined script attached to a Project. Surfaced in the Scripts
/// sub-pane, the Command Palette, and the WorktreeHeader Run split-button.
/// Runs as `$SHELL -c <command>` in a fresh tab on activation.
///
/// `kind` drives the default visual identity (name, icon, tint). For
/// predefined kinds (`.run` / `.test` / `.deploy` / `.lint` / `.format`)
/// the `systemImage` / `tintColor` overrides are stored but ignored at
/// render time — only `.custom` honours them. This keeps "the kind is the
/// contract" semantic so a list of `.test` scripts looks uniform.
public nonisolated struct ScriptDefinition: Equatable, Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var kind: ScriptKind
  public var name: String
  public var command: String
  public var systemImage: String?
  public var tintColor: ScriptTintColor?

  public init(
    id: UUID = UUID(),
    kind: ScriptKind = .run,
    name: String = "",
    command: String = "",
    systemImage: String? = nil,
    tintColor: ScriptTintColor? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.command = command
    self.systemImage = systemImage
    self.tintColor = tintColor
  }

  /// User-visible label. Falls back to the kind's default when the user
  /// has not named the script.
  public var displayName: String {
    name.isEmpty ? kind.defaultName : name
  }

  /// SF Symbol used by view-side icons. Predefined kinds always return the
  /// kind default; `.custom` returns the override when present.
  public var resolvedSystemImage: String {
    if kind == .custom, let systemImage, !systemImage.isEmpty {
      return systemImage
    }
    return kind.defaultSystemImage
  }

  /// Tint colour used by view-side icons / button accents. Predefined kinds
  /// always return the kind default; `.custom` returns the override.
  public var resolvedTintColor: ScriptTintColor {
    if kind == .custom, let tintColor {
      return tintColor
    }
    return kind.defaultTintColor
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, name, command, systemImage, tintColor
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    // `kind` defaults to `.run` so reserved-empty Phase 1 entries decode
    // without error and round-trip stably under Phase 2 schema.
    self.kind = try c.decodeIfPresent(ScriptKind.self, forKey: .kind) ?? .run
    self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
    self.tintColor = try c.decodeIfPresent(ScriptTintColor.self, forKey: .tintColor)
  }

  /// Omit-when-default encoding. Empty strings / nil overrides do not
  /// appear on disk so the JSON stays minimal for predefined kinds.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(kind, forKey: .kind)
    if !name.isEmpty {
      try c.encode(name, forKey: .name)
    }
    if !command.isEmpty {
      try c.encode(command, forKey: .command)
    }
    try c.encodeIfPresent(systemImage, forKey: .systemImage)
    try c.encodeIfPresent(tintColor, forKey: .tintColor)
  }
}
