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
  /// Called on `Return` from the rename popover. Empty-after-trim input
  /// is normalized to `nil` so the chip falls back on the default label.
  let onRenameCommit: (String?) -> Void

  @State private var isHovering = false
  @State private var isPressing = false
  /// Non-nil while the rename popover is presented. The context menu's
  /// Rename action seeds this with the current title; the popover edits
  /// its value and `commitRename` / `cancelRename` clear it. A dismissal
  /// via outside-click is routed through the popover binding setter and
  /// treated as a discard so no half-typed name ever commits.
  @State private var editingName: String?
  @FocusState private var renameFieldFocused: Bool

  var body: some View {
    HStack(spacing: 4) {
      Button(action: onSelect) {
        TabChipLabel(title: title, isDirty: isDirty)
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
    .popover(
      isPresented: renamePopoverBinding,
      arrowEdge: .bottom
    ) {
      renameCard
    }
  }

  /// Small rename card shown inside the popover. Pre-populates with the
  /// current title, commits on Return (default action), discards on Esc
  /// / Cancel / outside-click. TextField style is `.roundedBorder` so
  /// the card reads as a native macOS rename dialog rather than bare
  /// text-entry chrome.
  @ViewBuilder
  private var renameCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Rename Tab")
        .font(.headline)
      TextField("Tab name", text: renameBinding)
        .textFieldStyle(.roundedBorder)
        .focused($renameFieldFocused)
        .frame(width: 220)
        .onSubmit(commitRename)
        .onKeyPress(.escape) {
          cancelRename()
          return .handled
        }
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: cancelRename)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: commitRename)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(14)
    .onAppear {
      renameFieldFocused = true
    }
  }

  /// Two-way binding for the popover presentation flag. Opening the
  /// popover is driven by `startEditing()`; closing it via outside-click
  /// funnels through `cancelRename()` so no half-typed name commits.
  private var renamePopoverBinding: Binding<Bool> {
    Binding(
      get: { editingName != nil },
      set: { presented in
        if !presented { cancelRename() }
      }
    )
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
