import SwiftUI

/// Rounded-rectangle background for one tab chip. State-aware so chips
/// share a single background type — future state expansion (e.g. dirty
/// styling, selection outline) lives here rather than being scattered
/// across the chip view.
///
/// Renders top-only corners so the chip reads as a folder tab rather than
/// a floating card, and stamps a 2-pt accent-tinted underline on the top
/// edge when the tab is selected. All tokens come from `TabBarMetrics` /
/// `TabBarColors` so visual-system shifts are a one-file diff.
struct TabChipBackground: View {
  let isActive: Bool
  let isHovering: Bool
  let isPressing: Bool

  var body: some View {
    ZStack(alignment: .top) {
      UnevenRoundedRectangle(
        topLeadingRadius: TabBarMetrics.chipCornerRadius,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: TabBarMetrics.chipCornerRadius
      )
      .fill(backgroundFill)

      if isActive {
        Rectangle()
          .fill(TabBarColors.activeUnderline)
          .frame(height: TabBarMetrics.activeUnderlineHeight)
      }
    }
  }

  /// Pressed chips fall back on the active fill so the chip feels rooted
  /// under the pointer even before the selection commits.
  private var backgroundFill: Color {
    if isActive || isPressing { return TabBarColors.activeBackground }
    if isHovering { return TabBarColors.hoverBackground }
    return TabBarColors.idleBackground
  }
}
