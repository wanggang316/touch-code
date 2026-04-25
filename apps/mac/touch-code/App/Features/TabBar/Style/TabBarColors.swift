import SwiftUI

/// Semantic color tokens for the Tab bar. Each token maps to a role, not a
/// hex value, so dark-mode and accent-color changes propagate without
/// per-view overrides. Any visual-system shift lives here, not in the
/// individual chip views.
enum TabBarColors {
  /// Chip background when the tab is not selected and the pointer is
  /// elsewhere.
  static let idleBackground: Color = .clear

  /// Chip background while the pointer is over it but the mouse button
  /// is up. Subtle so it reads as affordance, not selection.
  static let hoverBackground: Color = Color.primary.opacity(0.06)

  /// Chip background for the selected tab and for any chip with its mouse
  /// button held down. Matches the native-control fill so active chips
  /// feel rooted in the window chrome.
  static let activeBackground: Color = Color(nsColor: .controlBackgroundColor)

  /// Accent-tinted underline sitting on the top edge of the active chip.
  static let activeUnderline: Color = .accentColor

  /// Separator drawn between adjacent idle chips. Hidden adjacent to the
  /// active chip so the underline carries the boundary.
  static let divider: Color = Color(nsColor: .separatorColor).opacity(0.7)

  /// Foreground tint for the close-button glyph.
  static let closeButtonForeground: Color = Color.primary.opacity(0.7)
}
