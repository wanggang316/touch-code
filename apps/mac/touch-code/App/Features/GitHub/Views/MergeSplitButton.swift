import SwiftUI
import TouchCodeCore

/// Split-button for the Merge action. Primary face merges with the current default
/// strategy; the trailing caret opens a Menu with the three strategies plus a "Set as
/// default for this Project" sub-menu (per UI design Surface 2).
///
/// Hand-rolled chrome because SwiftUI's native button styles (`.borderedProminent` +
/// `.bordered` in an `HStack`) carry intrinsic outer margins that leave a visible gap
/// between the halves on macOS 26 — they read as two separate pills instead of one
/// split-button. The two halves here sit inside a single `Capsule()` clip with their
/// own fills (accent for Merge, neutral grey for the caret), so the control reads as
/// one frame with a primary + secondary region. Height matches the neighbouring
/// `.bordered` Close button thanks to the same control-size environment pinned on
/// `PullRequestPopover` (HAN-60).
struct MergeSplitButton: View {
  let defaultStrategy: MergeStrategy
  let isDisabled: Bool
  let disabledReason: String?
  let onMerge: (MergeStrategy) -> Void
  let onSetProjectDefault: (MergeStrategy) -> Void

  @State private var isPrimaryHovering = false
  @State private var isCaretHovering = false

  var body: some View {
    HStack(spacing: 0) {
      Button {
        onMerge(defaultStrategy)
      } label: {
        Text("Merge (\(defaultStrategy.shortName))")
          .font(.callout)
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(primaryFill)
      .onHover { isPrimaryHovering = $0 }
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
          .foregroundStyle(.primary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .background(caretFill)
      .onHover { isCaretHovering = $0 }
      .accessibilityLabel("Choose merge strategy")
    }
    .clipShape(Capsule(style: .continuous))
    .opacity(isDisabled ? 0.5 : 1.0)
    .disabled(isDisabled)
  }

  /// Accent fill for the primary half. Darkens slightly on hover so the
  /// otherwise-feedback-less `.buttonStyle(.plain)` still signals
  /// interactivity.
  private var primaryFill: some View {
    Color.accentColor
      .brightness(isPrimaryHovering && !isDisabled ? -0.05 : 0)
  }

  /// Neutral-grey fill for the caret half. Same hover darken so the two
  /// halves stay in step on press / hover.
  private var caretFill: some View {
    Color.secondary
      .opacity(isCaretHovering && !isDisabled ? 0.28 : 0.18)
  }
}
