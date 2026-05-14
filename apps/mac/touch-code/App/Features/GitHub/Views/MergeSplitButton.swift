import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. Primary face merges with the current default
/// strategy; the trailing caret opens a Menu with the three strategies plus a "Set as
/// default for this Project" sub-menu (per UI design Surface 2).
///
/// Layout: a `.borderedProminent` primary `Button` (accent-blue pill) glued to a
/// `.bordered` chevron `Menu` (neutral grey pill) via `spacing: 0`, so the two halves
/// read as a single split-button while each carries the system's native chrome —
/// height and corner radius match the neighbouring `.bordered` Close / Mark-ready /
/// Rerun-failed buttons. No hand-rolled outline.
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
      .menuStyle(.button)
      .buttonStyle(.bordered)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(isDisabled)
      .accessibilityLabel("Choose merge strategy")
    }
  }
}
