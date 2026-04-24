import SwiftUI

/// One tab chip. Composes label + close button on top of a state-aware
/// background. The chip accepts plain closures rather than a TCA store so it
/// stays agnostic of the feature that drives it — future milestones bolt
/// drag / middle-click / context-menu affordances onto the same shape
/// without widening that dependency.
///
/// Current behavior (M1-T1.2): preserves the pre-split layout exactly —
/// `HStack(spacing: 4)` of label + close button, 3-pt vertical + 4-pt
/// horizontal outer padding, background filled only when active.
struct TabChipView: View {
  let title: String
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Button(action: onSelect) {
        TabChipLabel(title: title)
      }
      .buttonStyle(.plain)
      TabChipCloseButton(action: onClose)
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 4)
    .background(TabChipBackground(isActive: isActive))
  }
}
