import SwiftUI

/// One tab chip. Composes label + close button on top of a state-aware
/// background and owns the chip's local hover / press / editing state. The
/// chip accepts plain closures rather than a TCA store so it stays
/// agnostic of the feature that drives it — future milestones bolt drag /
/// middle-click affordances onto the same shape without widening that
/// dependency.
struct TabChipView: View {
  let title: String
  let isActive: Bool
  let isOnlyTab: Bool
  let isLastTab: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void
  /// Called on `Return` from the inline rename field. Empty input is
  /// normalized to `nil` so the chip falls back on the default label.
  let onRenameCommit: (String?) -> Void

  @State private var isHovering = false
  @State private var isPressing = false
  /// Non-nil while the user is editing the tab name inline. M2-T2.3 flips
  /// this to `""` from the context menu; the TextField path and submit /
  /// cancel wiring land in M2-T2.4.
  @State private var editingName: String?

  var body: some View {
    HStack(spacing: 4) {
      Button(action: onSelect) {
        TabChipLabel(title: title)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(ChipPressTrackingStyle(isPressing: $isPressing))

      TabChipCloseButton(
        isVisible: isHovering || isActive,
        action: onClose
      )
    }
    .padding(.horizontal, TabBarMetrics.chipHorizontalPadding)
    .frame(
      minWidth: TabBarMetrics.chipMinWidth,
      maxWidth: TabBarMetrics.chipMaxWidth
    )
    .frame(height: TabBarMetrics.chipHeight)
    .background(
      TabChipBackground(
        isActive: isActive,
        isHovering: isHovering,
        isPressing: isPressing
      )
    )
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.10)) {
        isHovering = hovering
      }
    }
    .contextMenu {
      TabChipContextMenu(
        isOnlyTab: isOnlyTab,
        isLastTab: isLastTab,
        onRename: { editingName = title },
        onClose: onClose,
        onCloseOthers: onCloseOthers,
        onCloseToRight: onCloseToRight,
        onCloseAll: onCloseAll
      )
    }
  }
}

/// Button style that exposes `isPressed` as a binding so the chip can
/// recolor its background during a tap without capturing pointer events
/// away from the surrounding hover handler.
private struct ChipPressTrackingStyle: ButtonStyle {
  @Binding var isPressing: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .onChange(of: configuration.isPressed) { _, newValue in
        isPressing = newValue
      }
  }
}
