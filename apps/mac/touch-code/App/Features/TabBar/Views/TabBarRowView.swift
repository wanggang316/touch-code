import SwiftUI
import TouchCodeCore
import UniformTypeIdentifiers

/// Horizontal row of tab chips. Kept thin so feature dispatch stays out of
/// the chip views — select / close / rename / reorder callbacks come from
/// the parent.
///
/// Chips sit flush against one another (`spacing: 0`) and a thin vertical
/// separator is stamped between any two adjacent non-active chips. The
/// separator is suppressed on either side of the active chip so its
/// accent underline visually carries the boundary.
///
/// Reorder: each chip emits its `TabID.raw.uuidString` via `.onDrag`; a
/// sibling `ChipDropDelegate` attached to every chip translates the drop
/// target into a reordered id list and dispatches once via
/// `onReorder`. A `spring(response: 0.3, dampingFraction: 0.85)` on the
/// id list animates the layout settle after the catalog updates.
struct TabBarRowView: View {
  let tabs: [TouchCodeCore.Tab]
  let activeTabID: TabID?
  /// Per-tab dirty lookup. Typically backed by
  /// `HierarchyManager.tabIsDirty(_:)` so SwiftUI observation re-renders
  /// the row when a pane's running state flips. Default is a no-op
  /// returning `false` for callers / previews that do not need dirty
  /// coverage.
  var isDirty: (TabID) -> Bool = { _ in false }
  /// Resolves the chip title. The default mirrors the legacy behavior
  /// (`tab.name` with a static fallback) so previews / call sites that
  /// don't care about live OSC titles compile without changes.
  var displayName: (TouchCodeCore.Tab, Int) -> String = { tab, index in
    tab.name ?? "Tab \(index)"
  }
  let onSelect: (TabID) -> Void
  let onClose: (TabID) -> Void
  let onMiddleClick: (TabID) -> Void
  let onCloseOthers: (TabID) -> Void
  let onCloseToRight: (TabID) -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: (TabID) -> Void
  let onReorder: @MainActor @Sendable ([TabID]) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
        TabChipView(
          title: displayName(tab, index + 1),
          isActive: activeTabID == tab.id,
          isDirty: isDirty(tab.id),
          isOnlyTab: tabs.count <= 1,
          isLastTab: index == tabs.count - 1,
          onSelect: { onSelect(tab.id) },
          onClose: { onClose(tab.id) },
          onMiddleClick: { onMiddleClick(tab.id) },
          onCloseOthers: { onCloseOthers(tab.id) },
          onCloseToRight: { onCloseToRight(tab.id) },
          onCloseAll: onCloseAll,
          onRenameRequested: { onRenameRequested(tab.id) }
        )
        .id(tab.id)
        .onDrag {
          NSItemProvider(object: tab.id.raw.uuidString as NSString)
        }
        .onDrop(
          of: [.plainText],
          delegate: ChipDropDelegate(
            targetID: tab.id,
            tabs: tabs,
            commit: onReorder
          )
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
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tabs.map(\.id))
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

/// DropDelegate that treats the drop payload as a source `TabID.raw` UUID
/// string, computes the new order (source removed + reinserted at the
/// target's index), and dispatches a single `commit` — matching the
/// exec-plan's D3 ("dispatch once on drop, not per tick"). Intra-row
/// self-drops are no-ops.
private struct ChipDropDelegate: DropDelegate {
  let targetID: TabID
  let tabs: [TouchCodeCore.Tab]
  let commit: @MainActor @Sendable ([TabID]) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.plainText])
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let provider = info.itemProviders(for: [.plainText]).first else {
      return false
    }
    let targetID = self.targetID
    let ids = tabs.map(\.id)
    provider.loadObject(ofClass: NSString.self) { [commit] loaded, _ in
      guard let raw = loaded as? String,
            let uuid = UUID(uuidString: raw)
      else { return }
      let sourceID = TabID(raw: uuid)
      guard sourceID != targetID,
            let sourceIdx = ids.firstIndex(of: sourceID),
            let targetIdx = ids.firstIndex(of: targetID)
      else { return }
      var reordered = ids
      reordered.remove(at: sourceIdx)
      // After removing the source, the original target index still
      // points at the same chip (shifted left by one if source < target).
      // Inserting `sourceID` at that index yields "drop into target's
      // current slot" semantics — the dropped chip lands where the
      // target was and pushes the target one step toward the source's
      // old side. This matches macOS Finder / Safari tab drag behavior.
      // Clamp defensively in case the array shrinks unexpectedly.
      reordered.insert(sourceID, at: min(targetIdx, reordered.count))
      // NSItemProvider invokes this callback off the main actor; hop back
      // onto MainActor so the non-Sendable TCA-store closure fires on the
      // correct isolation domain.
      Task { @MainActor in
        commit(reordered)
      }
    }
    return true
  }
}
