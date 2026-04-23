import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. Primary face merges with the current default
/// strategy; the caret half opens a Menu with the three strategies plus a "Set as default
/// for this Project" sub-menu (per UI design Surface 2).
///
/// Mirrors the shape of `WorktreeHeaderOpenButton` (0009 MW-T2) so the two live in one
/// interaction idiom across the app.
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
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
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
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .disabled(isDisabled)
      .fixedSize()
    }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
    )
  }
}
