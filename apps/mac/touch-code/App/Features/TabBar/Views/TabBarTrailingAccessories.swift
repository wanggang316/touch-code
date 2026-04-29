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
      Button(action: onNewTab) {
        Image(systemName: "plus")
          .accessibilityLabel("New Tab")
          .commandKeyHint(.newTab)
      }
      .buttonStyle(.borderless)

      SplitAccessoryButton(
        systemImage: "rectangle.split.2x1",
        accessibilityLabel: "Split Right",
        splitTree: activeTabSplitTree,
        action: onSplitRight
      )

      SplitAccessoryButton(
        systemImage: "rectangle.split.1x2",
        accessibilityLabel: "Split Down",
        splitTree: activeTabSplitTree,
        action: onSplitDown
      )
    }
    .padding(.horizontal, 6)
  }
}

/// Trailing split button. Owns its own hover-delay bookkeeping so the
/// preview popover opens only after a 350-ms linger and dismisses on
/// pointer exit. The popover is never modal and never steals focus.
private struct SplitAccessoryButton: View {
  let systemImage: String
  let accessibilityLabel: String
  let splitTree: SplitTree<PaneID>?
  let action: () -> Void

  @State private var isPreviewing = false
  @State private var hoverTask: Task<Void, Never>?

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .accessibilityLabel(accessibilityLabel)
    }
    .buttonStyle(.borderless)
    .disabled(splitTree?.root == nil)
    .onHover(perform: handleHover)
    .popover(isPresented: $isPreviewing, arrowEdge: .bottom) {
      if let tree = splitTree {
        SplitPreviewPopoverView(tree: tree)
      }
    }
  }

  private func handleHover(_ hovering: Bool) {
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
