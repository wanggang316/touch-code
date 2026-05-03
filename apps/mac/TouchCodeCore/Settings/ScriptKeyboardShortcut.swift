import Foundation

/// Per-`ScriptDefinition` keyboard chord. Stored on the model so a
/// shortcut survives across launches and round-trips through the
/// settings JSON. UI-framework-free — the SwiftUI `.keyboardShortcut`
/// adapter lives in the app target so `TouchCodeCore` stays free of
/// SwiftUI / AppKit imports.
///
/// The chord is `(modifiers, key)`. `key` is a single character such as
/// `"r"`. `modifiers` is a Set so the on-disk representation is
/// order-stable — the encoder emits a sorted array.
public nonisolated struct ScriptKeyboardShortcut: Equatable, Codable, Sendable, Hashable {
  /// Single character key, lower-case by convention. The view-layer
  /// adapter normalises `Character` casing when matching against
  /// SwiftUI's `KeyEquivalent`.
  public var key: String
  public var modifiers: Set<Modifier>

  public init(key: String, modifiers: Set<Modifier>) {
    self.key = key
    self.modifiers = modifiers
  }

  public enum Modifier: String, Codable, CaseIterable, Sendable, Hashable {
    case command, option, control, shift
  }

  /// macOS-conventional rendering: `⌃⌥⇧⌘R`. Order matches the system
  /// menu / cheat-sheet convention so users can pattern-match it
  /// against their existing knowledge.
  public var displayString: String {
    var s = ""
    if modifiers.contains(.control) { s += "⌃" }
    if modifiers.contains(.option) { s += "⌥" }
    if modifiers.contains(.shift) { s += "⇧" }
    if modifiers.contains(.command) { s += "⌘" }
    s += key.uppercased()
    return s
  }

  /// True when the chord has both a key and at least one modifier.
  /// macOS bare-key shortcuts (no modifier) collide with text input
  /// almost everywhere; the editor UI gates Save on this predicate.
  public var isValid: Bool {
    !key.isEmpty && !modifiers.isEmpty
  }

  // MARK: - Codable (sorted modifiers for diff stability)

  private enum CodingKeys: String, CodingKey { case key, modifiers }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.key = try c.decode(String.self, forKey: .key)
    let array = try c.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
    self.modifiers = Set(array)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key)
    if !modifiers.isEmpty {
      try c.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
    }
  }
}
