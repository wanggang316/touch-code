import SwiftUI

/// The text portion of a tab chip. Kept separate from the chip container so
/// it owns its own typography + truncation discipline. Future milestones
/// drop a leading running-state indicator here without touching the chip's
/// layout spine.
///
/// Truncates in the middle so both ends of the title remain visible — a
/// long path's filename stays readable even as it's clipped.
struct TabChipLabel: View {
  let title: String

  var body: some View {
    Text(title)
      .lineLimit(1)
      .truncationMode(.middle)
      .font(.system(size: 12))
  }
}
