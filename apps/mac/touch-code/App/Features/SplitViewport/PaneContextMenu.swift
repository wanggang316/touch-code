import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Pure model for the pane right-click context menu. Reading and writing
/// pane labels go through closures so the menu's logic stays testable
/// without spinning up a SwiftUI view tree (notifications-v1-1 M7.T1
/// AC-V11-M-001 / M-002 cover the toggle behaviour).
struct PaneContextMenuModel {
  let paneID: PaneID
  let snapshot: () -> Catalog
  let setLabel: (PaneID, String, Bool) -> Void

  var isMuted: Bool {
    snapshot().pane(paneID)?.labels.contains(InboxLabels.muted) ?? false
  }

  func toggleMute() {
    setLabel(paneID, InboxLabels.muted, !isMuted)
  }
}

/// Right-click menu for a pane. Currently hosts only the "Mute
/// notifications" toggle for notifications-v1-1; future menu items can
/// be added here without churning `LazyPaneHost`.
///
/// The menu reads `HierarchyClient.snapshot()` lazily inside
/// `PaneContextMenuModel.isMuted` on every render so the checkmark
/// reflects the latest label state when the user re-opens the menu —
/// the per-pane mute label flips elsewhere are picked up without an
/// explicit observer.
struct PaneContextMenu: View {
  let paneID: PaneID
  @Dependency(HierarchyClient.self) private var hierarchy

  private var model: PaneContextMenuModel {
    PaneContextMenuModel(
      paneID: paneID,
      snapshot: hierarchy.snapshot,
      setLabel: hierarchy.setPaneLabel
    )
  }

  var body: some View {
    Button {
      model.toggleMute()
    } label: {
      Label(
        "Mute notifications",
        systemImage: model.isMuted ? "checkmark" : "bell.slash"
      )
    }
  }
}
