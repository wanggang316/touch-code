import SwiftUI
import TouchCodeCore

/// Horizontal row of tab chips. Kept thin so M2 can attach a drag-reorder
/// gesture here without re-plumbing the parent container.
///
/// Current behavior (M1-T1.2): iterates `tabs` in order and renders one
/// `TabChipView` per tab with `spacing: 4`, preserving the pre-split layout.
struct TabBarRowView: View {
  let tabs: [TouchCodeCore.Tab]
  let activeTabID: TabID?
  let onSelect: (TabID) -> Void
  let onClose: (TabID) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(tabs) { tab in
        TabChipView(
          title: tab.name ?? "Tab",
          isActive: activeTabID == tab.id,
          onSelect: { onSelect(tab.id) },
          onClose: { onClose(tab.id) }
        )
      }
    }
  }
}
