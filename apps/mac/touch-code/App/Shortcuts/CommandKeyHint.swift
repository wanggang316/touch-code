import SwiftUI
import TouchCodeCore

extension View {
  /// Overlays a chord keycap on this view while the user holds ⌘. Pairs with
  /// `appKeyboardShortcut(_:)`: that modifier binds the chord, this one surfaces
  /// it in-place so users discover the binding without opening the menu — same
  /// affordance the sidebar's worktree rows ship inline.
  ///
  /// Reads `CommandKeyObserver` and `\.resolvedShortcuts` from the environment
  /// (both already injected at the main scene root). No-op when the modifier
  /// is the user is not holding ⌘, when the resolved entry is missing /
  /// disabled, or when the chord has no displayable binding.
  func commandKeyHint(
    _ id: CommandID,
    alignment: Alignment = .topTrailing
  ) -> some View {
    modifier(CommandKeyHintModifier(id: id, alignment: alignment))
  }
}

private struct CommandKeyHintModifier: ViewModifier {
  let id: CommandID
  let alignment: Alignment
  @Environment(CommandKeyObserver.self) private var observer
  @Environment(\.resolvedShortcuts) private var shortcuts

  func body(content: Content) -> some View {
    content.overlay(alignment: alignment) {
      if observer.isCommandHeld,
        let resolved = shortcuts[id], resolved.isEnabled,
        let binding = resolved.binding
      {
        Text(ShortcutDisplay.chord(for: binding))
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: 3)
              .fill(.regularMaterial)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 3)
              .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
          )
          .offset(offsetForAlignment(alignment))
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
    }
  }

  /// Nudges the keycap a few points outward so it sits just past the host
  /// view's edge rather than directly over its content.
  private func offsetForAlignment(_ alignment: Alignment) -> CGSize {
    switch alignment {
    case .topLeading: return CGSize(width: -4, height: -4)
    case .topTrailing: return CGSize(width: 4, height: -4)
    case .bottomLeading: return CGSize(width: -4, height: 4)
    case .bottomTrailing: return CGSize(width: 4, height: 4)
    case .top: return CGSize(width: 0, height: -6)
    case .bottom: return CGSize(width: 0, height: 6)
    case .leading: return CGSize(width: -6, height: 0)
    case .trailing: return CGSize(width: 6, height: 0)
    default: return .zero
    }
  }
}
