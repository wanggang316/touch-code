import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. The primary face merges with the
/// current default strategy; the caret half opens a menu with the three
/// strategies plus a "Set as default for this Project" sub-menu (per UI
/// design Surface 2).
///
/// Implemented via SwiftUI's native `Menu(primaryAction:)` with
/// `.borderedProminent` so the system paints the same pill chrome the
/// neighbouring `.bordered` buttons (Close / Mark ready / Rerun failed)
/// use — keeping the corner radius and height in lockstep across the
/// action row. The earlier hand-rolled `HStack { Button + Menu }` inside
/// a custom 6pt-radius outline clashed with macOS 26's pill rendering
/// (HAN-60 follow-up).
struct MergeSplitButton: View {
  let defaultStrategy: MergeStrategy
  let isDisabled: Bool
  let disabledReason: String?
  let onMerge: (MergeStrategy) -> Void
  let onSetProjectDefault: (MergeStrategy) -> Void

  var body: some View {
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
      Text("Merge (\(defaultStrategy.shortName))")
    } primaryAction: {
      onMerge(defaultStrategy)
    }
    .menuStyle(.button)
    .buttonStyle(.borderedProminent)
    .disabled(isDisabled)
    .help(isDisabled ? (disabledReason ?? "") : "Merge with \(defaultStrategy.displayName)")
  }
}
