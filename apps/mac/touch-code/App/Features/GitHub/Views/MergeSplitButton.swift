import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. Primary face merges with the current default
/// strategy; the caret half opens a Menu with the three strategies plus a "Set as default
/// for this Project" sub-menu (per UI design Surface 2).
///
/// Layout is a `.borderedProminent` primary `Button` (accent-blue capsule) plus a
/// borderless caret `Menu`, both wrapped in a single `Capsule(style: .continuous)`
/// stroke so the chevron area shares one frame with the Merge half. The outer
/// `Capsule` matches the inner pill's curvature on macOS 26; the sibling Close /
/// Mark-ready / Rerun-failed buttons in `PullRequestPopover` are styled
/// `.borderedProminent` with a grey tint so the whole action row reads as
/// uniformly-shaped capsules — only the colour distinguishes primary from
/// secondary actions.
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
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .disabled(isDisabled)
      .fixedSize()
    }
    .background(
      Capsule(style: .continuous)
        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
    )
  }
}
