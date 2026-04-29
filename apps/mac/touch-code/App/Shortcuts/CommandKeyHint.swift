import SwiftUI
import TouchCodeCore

extension View {
  /// While the user holds ⌘, append the chord bound to `id` after this view —
  /// inline in the same `HStack`, so the chord becomes part of the button /
  /// label it decorates rather than a floating overlay. Visually matches the
  /// macOS menu convention "Item Name  ⌘⇧O".
  ///
  /// Apply this on the *label* of a Button / Menu (not the Button itself) so
  /// the chord text stays inside the button's hit area and lays out with the
  /// rest of the label content. Reads `CommandKeyObserver` and
  /// `\.resolvedShortcuts` from the environment, both already injected at the
  /// main scene root. Renders nothing while ⌘ is not held, when the resolved
  /// entry is missing/disabled, or when the chord has no displayable binding.
  func commandKeyHint(_ id: CommandID) -> some View {
    modifier(CommandKeyHintModifier(id: id))
  }
}

private struct CommandKeyHintModifier: ViewModifier {
  let id: CommandID
  @Environment(CommandKeyObserver.self) private var observer
  @Environment(\.resolvedShortcuts) private var shortcuts

  func body(content: Content) -> some View {
    HStack(spacing: 6) {
      content
      if let chord = chordText {
        Text(chord)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
  }

  private var chordText: String? {
    guard observer.isCommandHeld,
      let resolved = shortcuts[id], resolved.isEnabled,
      let binding = resolved.binding
    else { return nil }
    return ShortcutDisplay.chord(for: binding)
  }
}
