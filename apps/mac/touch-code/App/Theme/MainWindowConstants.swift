import CoreGraphics

/// Constants used by the main-window T3 Git Viewer overlay. Kept as a
/// scoped namespace so the values are easy to tune from one place and
/// unit-testable through the `WorktreeDetailView.shouldShowOverlay`
/// helper.
enum MainWindowConstants {
  /// Fixed width of the right-edge Git Viewer overlay.
  static let gvOverlayWidth: CGFloat = 360

  /// Minimum terminal width the overlay is allowed to leave. When the
  /// host's width falls below `gvOverlayWidth + gvOverlayMinTerminalWidth`
  /// the overlay is suppressed for that layout pass; the underlying
  /// `Worktree.gitViewerVisible` state is preserved.
  static let gvOverlayMinTerminalWidth: CGFloat = 480
}
