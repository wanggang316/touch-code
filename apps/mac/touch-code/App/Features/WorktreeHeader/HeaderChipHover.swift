import SwiftUI

/// Hover-aware fill for individually clickable regions inside the
/// Worktree header's trailing split chips. Each half (primary + caret)
/// paints its own subtle rounded fill on hover so the user gets
/// per-half feedback rather than the entire chip lighting up.
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
