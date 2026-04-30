import SwiftUI

/// The text portion of a tab chip. Kept separate from the chip container so
/// it owns its own typography + truncation discipline.
///
/// When `isDirty` is `true`, a 12×12 mini progress spinner leads the label
/// to signal that some pane inside the tab is executing a tracked command.
/// The slot collapses to zero when `isDirty` is `false` so the label sits
/// flush with the chip edge the rest of the time. Writers for the dirty
/// signal land with the C3 hooks plan; M3 wires only the read path.
///
/// Truncates in the middle so both ends of the title remain visible — a
/// long path's filename stays readable even as it's clipped.
struct TabChipLabel: View {
  let title: String
  var isActive: Bool = false
  var isDirty: Bool = false
  /// L2 unread dot. Rendered as a 4 px filled circle immediately before
  /// the title text. Boolean only — no count, no kind distinction.
  var hasUnreadNotification: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      if isDirty {
        ProgressView()
          .controlSize(.mini)
          .frame(width: 12, height: 12)
      }
      if hasUnreadNotification {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 4, height: 4)
          .accessibilityLabel("Has unread notifications")
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.caption)
        .foregroundStyle(isActive ? TabBarColors.activeText : TabBarColors.inactiveText)
    }
  }
}
