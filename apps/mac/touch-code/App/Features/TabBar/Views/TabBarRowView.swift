import SwiftUI
import TouchCodeCore

/// Horizontal row of tab chips. Kept thin so M2 can attach a drag-reorder
/// gesture here without re-plumbing the parent container.
///
/// Chips sit flush against one another (`spacing: 0`) and a thin vertical
/// separator is stamped between any two adjacent non-active chips. The
/// separator is suppressed on either side of the active chip so its
/// accent underline visually carries the boundary.
struct TabBarRowView: View {
  let tabs: [TouchCodeCore.Tab]
  let activeTabID: TabID?
  let onSelect: (TabID) -> Void
  let onClose: (TabID) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
        TabChipView(
          title: tab.name ?? "Tab",
          isActive: activeTabID == tab.id,
          onSelect: { onSelect(tab.id) },
          onClose: { onClose(tab.id) }
        )
        if shouldShowDivider(after: index) {
          Rectangle()
            .fill(TabBarColors.divider)
            .frame(
              width: TabBarMetrics.dividerWidth,
              height: TabBarMetrics.dividerHeight
            )
        }
      }
    }
  }

  /// A divider appears between two chips only if neither of them is the
  /// active chip — the active chip's underline already carries the visual
  /// boundary on its own sides.
  private func shouldShowDivider(after index: Int) -> Bool {
    guard index < tabs.count - 1 else { return false }
    let currentID = tabs[index].id
    let nextID = tabs[index + 1].id
    return currentID != activeTabID && nextID != activeTabID
  }
}
