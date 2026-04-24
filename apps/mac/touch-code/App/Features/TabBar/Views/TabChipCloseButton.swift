import SwiftUI

/// The `xmark` button on the trailing edge of a tab chip. A dedicated view
/// so later milestones can add hover-reveal, keyboard shortcut hints, and
/// middle-click semantics without widening `TabChipView`.
///
/// Current behavior (M1-T1.2): always visible at 0.6 opacity, matching the
/// pre-split chip. Hover-revealed + focus styling lands in M1-T1.3.
struct TabChipCloseButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.caption2)
        .accessibilityLabel("Close Tab")
    }
    .buttonStyle(.borderless)
    .opacity(0.6)
  }
}
