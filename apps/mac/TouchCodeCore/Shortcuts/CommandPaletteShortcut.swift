import Foundation

/// Single source of truth for the Command Palette's keyboard shortcut.
///
/// Two consumers today read this at build time:
///   * `MainWindowCommands` binds the `⌘P` menu entry via
///     `KeyEquivalent(CommandPaletteShortcut.keyChar)`.
///   * `StatusMotivationalView` renders `Open Command Palette <display>`
///     as the default titlebar hint when no PR / toast covers the slot.
///
/// Kept as String + Character — SwiftUI's `EventModifiers` is a SwiftUI
/// type and TouchCodeCore intentionally does not import SwiftUI. Callers
/// in the app tier combine `keyChar` with their own `.command` modifier.
public enum CommandPaletteShortcut {
  /// Base key — literal character passed to `KeyEquivalent`.
  public static let keyChar: Character = "p"

  /// Human-readable shortcut for hint text. macOS convention: ⌘ glyph +
  /// uppercase keycap. Displayed verbatim in motivational hints and
  /// accessibility strings.
  public static let displayString: String = "⌘P"
}
