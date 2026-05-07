import SwiftUI
import TouchCodeCore

/// Fixed-position controls on the trailing edge of the Tab bar. Lives
/// outside the scrollable chip row so these buttons stay visible
/// regardless of how many tabs are open.
///
/// Three actions: `+` creates a new tab in the active worktree; the two
/// split buttons cut a new pane horizontally or vertically off the active
/// tab's leftmost leaf. Hovering either split button for
/// `TabBarMetrics.hoverPreviewDelay` shows a miniature preview popover of
/// the active tab's split tree.
struct TabBarTrailingAccessories: View {
  let activeTabSplitTree: SplitTree<PaneID>?
  let onNewTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitDown: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      NewTabAccessoryButton(action: onNewTab)

      SplitAccessoryButton(
        systemImage: "rectangle.split.2x1",
        accessibilityLabel: "Split Right",
        chordCommandID: .splitRight,
        splitTree: activeTabSplitTree,
        action: onSplitRight
      )

      SplitAccessoryButton(
        systemImage: "rectangle.split.1x2",
        accessibilityLabel: "Split Down",
        chordCommandID: .splitDown,
        splitTree: activeTabSplitTree,
        action: onSplitDown
      )
    }
    .padding(.horizontal, 6)
  }
}

/// 22×22 circular hover affordance shared by the trailing accessories.
/// Mirrors the sidebar `iconLabel` chrome so the +/split row reads as
/// the same family of toolbar icon buttons. `TabBarColors.hoverBackground`
/// gives the standard tab-bar tint; the `Circle()` shape rounds the hit
/// target without changing the underlying button hit detection.
private struct AccessoryIconChrome: ViewModifier {
  let isHovering: Bool

  func body(content: Content) -> some View {
    content
      .frame(width: 22, height: 22)
      .background(
        Circle()
          .fill(isHovering ? TabBarColors.hoverBackground : .clear)
      )
      .contentShape(Circle())
  }
}

/// `+` button. Split into its own view so the hover state is local and
/// doesn't redraw siblings on every pointer crossing.
private struct NewTabAccessoryButton: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .accessibilityLabel("New Tab")
        .commandKeyHint(.newTab)
        .modifier(AccessoryIconChrome(isHovering: isHovering))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .helpWithShortcut("New Tab", .newTab)
  }
}

/// Trailing split button. Owns its own hover-delay bookkeeping so the
/// preview popover opens only after a 350-ms linger and dismisses on
/// pointer exit. The popover is never modal and never steals focus.
private struct SplitAccessoryButton: View {
  let systemImage: String
  let accessibilityLabel: String
  /// Registry chord this button mirrors (`.splitRight` / `.splitDown`). The image
  /// surfaces the chord inline while ⌘ is held so the user can discover the
  /// keyboard binding without opening the menu.
  let chordCommandID: CommandID
  let splitTree: SplitTree<PaneID>?
  let action: () -> Void

  @State private var isPreviewing = false
  @State private var isHovering = false
  @State private var hoverTask: Task<Void, Never>?

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .accessibilityLabel(accessibilityLabel)
        .commandKeyHint(chordCommandID)
        .modifier(AccessoryIconChrome(isHovering: isHovering))
    }
    .buttonStyle(.plain)
    .disabled(splitTree?.root == nil)
    .onHover(perform: handleHover)
    .helpWithShortcut(accessibilityLabel, chordCommandID)
    .popover(isPresented: $isPreviewing, arrowEdge: .bottom) {
      if let tree = splitTree {
        SplitPreviewPopoverView(tree: tree)
      }
    }
  }

  private func handleHover(_ hovering: Bool) {
    isHovering = hovering
    hoverTask?.cancel()
    guard hovering, splitTree?.root != nil else {
      isPreviewing = false
      return
    }
    hoverTask = Task { @MainActor in
      try? await Task.sleep(for: TabBarMetrics.hoverPreviewDelay)
      guard !Task.isCancelled else { return }
      isPreviewing = true
    }
  }
}
