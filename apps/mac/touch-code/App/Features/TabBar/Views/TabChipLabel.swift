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
  var isDirty: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      if isDirty {
        ProgressView()
          .controlSize(.mini)
          .frame(width: 12, height: 12)
      }
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.system(size: 12))
    }
  }
}
