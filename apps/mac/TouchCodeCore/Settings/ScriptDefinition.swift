import Foundation

/// User-defined script attached to a Project. Surfaced in the Scripts
/// sub-pane, the Command Palette, and the WorktreeHeader Run split-button.
///
/// `kind` drives the default visual identity (name, icon, tint). For
/// predefined kinds (`.run` / `.test` / `.deploy` / `.lint` / `.format`)
/// the `systemImage` / `tintColor` overrides are stored but ignored at
/// render time — only `.custom` honours them. This keeps "the kind is the
/// contract" semantic so a list of `.test` scripts looks uniform.
///
/// `target` / `direction` / `onFinished` describe **how** the script
/// materializes at run time:
/// - `target` picks between writing into the focused pane, a new tab, or a
///   split off the focused pane.
/// - `direction` is consumed only when `target == .split`.
/// - `onFinished` is consumed only for surface-spawning targets (`.newTab`,
///   `.split`); `.focused` has no observable completion boundary so the
///   runtime treats it as `.none` regardless.
public nonisolated struct ScriptDefinition: Equatable, Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var kind: ScriptKind
  public var name: String
  public var command: String
  public var systemImage: String?
  public var tintColor: ScriptTintColor?
  public var target: ScriptTarget
  public var direction: ScriptSplitDirection
  public var onFinished: ScriptOnFinished
  /// Optional global keyboard chord (e.g. ⌘⇧R) attached to this
  /// script. nil = no shortcut. Bound at the worktree-header
  /// split-button menu via SwiftUI's `.keyboardShortcut(_:modifiers:)`,
  /// which fires the same dispatch path as a manual menu pick.
  public var keyboardShortcut: ScriptKeyboardShortcut?

  public init(
    id: UUID = UUID(),
    kind: ScriptKind = .run,
    name: String = "",
    command: String = "",
    systemImage: String? = nil,
    tintColor: ScriptTintColor? = nil,
    target: ScriptTarget = .newTab,
    direction: ScriptSplitDirection = .right,
    onFinished: ScriptOnFinished = .none,
    keyboardShortcut: ScriptKeyboardShortcut? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.command = command
    self.systemImage = systemImage
    self.tintColor = tintColor
    self.target = target
    self.direction = direction
    self.onFinished = onFinished
    self.keyboardShortcut = keyboardShortcut
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

  /// Validates `onFinished` against `target`. The UI never writes invalid
  /// combinations, but a hand-edited `settings.json` could; the runtime
  /// reads through this so dispatch is defensive.
  public var resolvedOnFinished: ScriptOnFinished {
    switch target {
    case .focused:
      return .none
    case .newTab:
      return onFinished == .closeTab ? .closeTab : .none
    case .split:
      return onFinished == .closePane ? .closePane : .none
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, name, command, systemImage, tintColor
    case target, direction, onFinished
    case keyboardShortcut
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.kind = try c.decodeIfPresent(ScriptKind.self, forKey: .kind) ?? .run
    self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    self.command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    self.systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
    self.tintColor = try c.decodeIfPresent(ScriptTintColor.self, forKey: .tintColor)
    self.target = try c.decodeIfPresent(ScriptTarget.self, forKey: .target) ?? .newTab
    self.direction = try c.decodeIfPresent(ScriptSplitDirection.self, forKey: .direction) ?? .right
    self.onFinished = try c.decodeIfPresent(ScriptOnFinished.self, forKey: .onFinished) ?? .none
    self.keyboardShortcut = try c.decodeIfPresent(ScriptKeyboardShortcut.self, forKey: .keyboardShortcut)
  }

  /// Omit-when-default encoding. Empty strings, nil overrides, and any field
  /// at its default value do not appear on disk so the JSON stays minimal.
  /// `direction` is only emitted when `target == .split`. `onFinished` is
  /// only emitted when the validated value is non-`.none`.
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
    if target != .newTab {
      try c.encode(target, forKey: .target)
    }
    if target == .split, direction != .right {
      try c.encode(direction, forKey: .direction)
    }
    let validatedOnFinished = resolvedOnFinished
    if validatedOnFinished != .none {
      try c.encode(validatedOnFinished, forKey: .onFinished)
    }
    // Only persist the chord when it's actually bindable (key + at
    // least one modifier). A half-typed shortcut left in the editor
    // sheet shouldn't survive unless the user explicitly saved a
    // valid one.
    if let chord = keyboardShortcut, chord.isValid {
      try c.encode(chord, forKey: .keyboardShortcut)
    }
  }
}
