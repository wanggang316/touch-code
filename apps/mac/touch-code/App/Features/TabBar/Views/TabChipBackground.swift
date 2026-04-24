import SwiftUI

/// Rounded-rectangle background for one tab chip. State-aware so chips
/// share a single background type — future state expansion (hover / press /
/// underline) lives here rather than being scattered across the chip view.
///
/// Current behavior (M1-T1.2): preserves the pre-split visual contract —
/// filled with `Color.accentColor.opacity(0.2)` on the active tab, clear
/// otherwise. Three-state background + active underline lands in M1-T1.3.
struct TabChipBackground: View {
  let isActive: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
  }
}
