import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. The primary face merges with the
/// current default strategy; the trailing dropdown opens a Menu with
/// the three strategies plus a "Set as default for this Project"
/// sub-menu (per UI design Surface 2).
///
/// Implemented with `Menu(primaryAction:)` + `.borderedProminent` so
/// macOS paints the entire control as a single accent-tinted pill with
/// a native split indicator — same height, same corner radius, same
/// chrome as the neighbouring action buttons in the popover. Earlier
/// hand-rolled forms (HStack + custom outline, or custom capsule with
/// hover state) all hit visual mismatches against the sibling buttons
/// on macOS 26.
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
    .buttonStyle(.borderedProminent)
    .disabled(isDisabled)
    .help(isDisabled ? (disabledReason ?? "") : "Merge with \(defaultStrategy.displayName)")
  }
}
