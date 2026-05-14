import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. The primary face merges with the
/// current default strategy; the trailing caret opens a menu with the
/// three strategies plus a "Set as default for this Project" sub-menu
/// (per UI design Surface 2).
///
/// Implemented as a primary `Button` plus a borderless `Menu` glued
/// side-by-side. Both halves use `.borderedProminent` so they share a
/// single accent-tinted pill chrome — height and corner radius then
/// match the neighbouring `.bordered` Close / Mark-ready / Rerun-failed
/// buttons that wrap the same way. The earlier `Menu(primaryAction:)` +
/// `.menuStyle(.button)` form silently dropped the prominent fill on
/// macOS 26, repainting the merge half as a neutral grey button.
struct MergeSplitButton: View {
  let defaultStrategy: MergeStrategy
  let isDisabled: Bool
  let disabledReason: String?
  let onMerge: (MergeStrategy) -> Void
  let onSetProjectDefault: (MergeStrategy) -> Void

  var body: some View {
    HStack(spacing: 2) {
      Button {
        onMerge(defaultStrategy)
      } label: {
        Text("Merge (\(defaultStrategy.shortName))")
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
      .buttonStyle(.borderedProminent)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(isDisabled)
      .accessibilityLabel("Choose merge strategy")
    }
  }
}
