import SwiftUI

/// One tab chip. Composes label + close button on top of a state-aware
/// background and owns the chip's local hover / press state. The chip
/// accepts plain closures rather than a TCA store so it stays agnostic
/// of the feature that drives it — future milestones bolt drag /
/// middle-click affordances onto the same shape without widening that
/// dependency.
///
/// Rename UX lives outside the chip: the context menu's Rename action
/// fires `onRenameRequested`, and the parent (`TabBarView`) presents
/// the editor as a window-attached sheet via `.sheet(item:)`. Keeping
/// the editor at the bar level avoids per-chip popover state and gives
/// rename a proper modal surface (matches the Prowl pattern).
struct TabChipView: View {
  let title: String
  let isActive: Bool
  let isDirty: Bool
  let isOnlyTab: Bool
  let isLastTab: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onMiddleClick: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: () -> Void

  @State private var isHovering = false
  @State private var isPressing = false

  var body: some View {
    // Supacode-style hit layout: the select Button claims the whole
    // chip rectangle so a click anywhere on the chip selects it; the
    // close button is overlaid on the trailing edge inside the same
    // ZStack so it intercepts its own taps without forwarding to the
    // outer Button. Without this, the previous HStack-of-Button-plus-
    // sibling layout left dead zones (between the label and the close
    // glyph, and on either chip-padding strip) that swallowed clicks.
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        TabChipLabel(title: title, isDirty: isDirty)
          .frame(maxWidth: .infinity, alignment: .leading)
          // Reserve space for the close glyph + its gap so long titles
          // truncate before they slide under the overlay.
          .padding(
            .trailing,
            TabBarMetrics.closeButtonSize + 4
          )
          .padding(.horizontal, TabBarMetrics.chipHorizontalPadding)
      }
      .buttonStyle(ChipPressTrackingStyle(isPressing: $isPressing))
      .frame(
        minWidth: TabBarMetrics.chipMinWidth,
        maxWidth: TabBarMetrics.chipMaxWidth
      )
      .frame(height: TabBarMetrics.chipHeight)
      .contentShape(Rectangle())

      TabChipCloseButton(
        isVisible: isHovering || isActive,
        action: onClose
      )
      .padding(.trailing, TabBarMetrics.chipHorizontalPadding)
    }
    .background(
      TabChipBackground(
        isActive: isActive,
        isHovering: isHovering,
        isPressing: isPressing
      )
    )
    .overlay(TabChipMiddleClickView(onMiddleClick: onMiddleClick))
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.10)) {
        isHovering = hovering
      }
    }
    .contextMenu {
      TabChipContextMenu(
        isOnlyTab: isOnlyTab,
        isLastTab: isLastTab,
        onRename: onRenameRequested,
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
