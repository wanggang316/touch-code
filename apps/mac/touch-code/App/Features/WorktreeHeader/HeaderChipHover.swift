import SwiftUI

/// Hover-aware fill for individually clickable regions in the Worktree
/// header's trailing toolbar chips. The header buttons use
/// `.buttonStyle(.borderless)` (and `.menuStyle(.borderlessButton)` for
/// menus), which suppresses macOS 26's native toolbar hover state — so
/// each split-button half (primary + caret) paints its own subtle
/// rounded fill on hover.
///
/// Apply per-half rather than per-chip so a split button lights up on
/// the side the cursor actually sits over, not the whole chip.
struct HeaderChipHover: ViewModifier {
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .background(
        Capsule(style: .continuous)
          .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
      )
      .contentShape(.capsule)
      .onHover { isHovering = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovering)
  }
}
