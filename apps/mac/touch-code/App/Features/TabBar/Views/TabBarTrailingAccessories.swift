import SwiftUI

/// Fixed-position controls on the trailing edge of the Tab bar. Lives outside
/// the scrollable chip row so `+` stays visible regardless of how many tabs
/// are open. M2 extends this with split-right / split-down buttons and a
/// hover-delayed pane-tree preview popover.
///
/// Current behavior (M1-T1.2): renders only the `+` new-tab button,
/// preserving the pre-split contract.
struct TabBarTrailingAccessories: View {
  let onNewTab: () -> Void

  var body: some View {
    Button(action: onNewTab) {
      Image(systemName: "plus")
        .accessibilityLabel("New Tab")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 6)
  }
}
