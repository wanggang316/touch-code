import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. Primary face merges with the current default
/// strategy; the caret half opens a Menu with the three strategies plus a "Set as default
/// for this Project" sub-menu (per UI design Surface 2).
///
/// Layout is a `.borderedProminent` primary `Button` plus a `.borderlessButton` `Menu`
/// for the chevron — the prominent half paints the accent pill, the borderless half
/// rides alongside as a transparent dropdown. The system supplies both halves' chrome,
/// so heights and corner radii match the neighbouring `.bordered` Close / Mark-ready /
/// Rerun-failed buttons without any hand-rolled outline.
struct MergeSplitButton: View {
  let defaultStrategy: MergeStrategy
  let isDisabled: Bool
  let disabledReason: String?
  let onMerge: (MergeStrategy) -> Void
  let onSetProjectDefault: (MergeStrategy) -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button {
        onMerge(defaultStrategy)
      } label: {
        Text("Merge (\(defaultStrategy.shortName))")
          .font(.callout)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isDisabled)
      .help(isDisabled ? (disabledReason ?? "") : "Merge with \(defaultStrategy.displayName)")

      Menu {
        ForEach(MergeStrategy.allCases, id: \.self) { strategy in
          Button(strategy.displayName) { onMerge(strategy) }
        }
        Divider()
        Menu("Set as default for this Project") {
          ForEach(MergeStrategy.allCases, id: \.self) { strategy in
            Button(strategy.displayName) { onSetProjectDefault(strategy) }
          }
        }
      } label: {
        Image(systemName: "chevron.down")
          .imageScale(.small)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .disabled(isDisabled)
      .fixedSize()
    }
  }
}
