import SwiftUI

/// The text portion of a tab chip. Kept separate from the chip container so
/// it owns its own typography + truncation discipline and so future milestones
/// can drop in a leading running-state indicator without touching the chip's
/// layout spine.
///
/// Current behavior (M1-T1.2): renders the title single-line with `.padding(
/// .horizontal, 8)`, matching the pre-split chip exactly. The `isDirty`
/// spinner slot arrives in M3 when the runtime read path lands.
struct TabChipLabel: View {
  let title: String

  var body: some View {
    Text(title)
      .lineLimit(1)
      .padding(.horizontal, 8)
  }
}
