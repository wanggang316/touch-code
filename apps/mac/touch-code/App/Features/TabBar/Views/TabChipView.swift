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
  let isDirty: Bool
  let isOnlyTab: Bool
  let isLastTab: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onMiddleClick: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void
  /// Called on `Return` from the inline rename field. Empty input is
  /// normalized to `nil` so the chip falls back on the default label.
  let onRenameCommit: (String?) -> Void

  @State private var isHovering = false
  @State private var isPressing = false
  /// Non-nil while the user is editing the tab name inline. Driven by the
  /// context menu's Rename action. `Return` commits through
  /// `onRenameCommit`; `Esc` discards.
  @State private var editingName: String?
  @FocusState private var renameFieldFocused: Bool

  var body: some View {
    HStack(spacing: 4) {
      if editingName != nil {
        renameField
      } else {
        Button(action: onSelect) {
          TabChipLabel(title: title, isDirty: isDirty)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChipPressTrackingStyle(isPressing: $isPressing))
      }

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
        onRename: startEditing,
        onClose: onClose,
        onCloseOthers: onCloseOthers,
        onCloseToRight: onCloseToRight,
        onCloseAll: onCloseAll
      )
    }
  }

  /// Inline `TextField` variant of the label. Trimmed empty input is
  /// normalized to `nil` so the chip falls back on the default "Tab"
  /// label. `.onKeyPress(.escape)` discards; `.onSubmit` commits.
  @ViewBuilder
  private var renameField: some View {
    TextField("", text: renameBinding)
      .textFieldStyle(.plain)
      .focused($renameFieldFocused)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onSubmit(commitRename)
      .onKeyPress(.escape) {
        cancelRename()
        return .handled
      }
      .onAppear {
        renameFieldFocused = true
      }
  }

  private var renameBinding: Binding<String> {
    Binding(
      get: { editingName ?? "" },
      set: { editingName = $0 }
    )
  }

  private func startEditing() {
    editingName = title
  }

  private func commitRename() {
    let trimmed = (editingName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    editingName = nil
    onRenameCommit(trimmed.isEmpty ? nil : trimmed)
  }

  private func cancelRename() {
    editingName = nil
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
