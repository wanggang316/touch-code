import AppKit
import SwiftUI

/// Runtime marker that records the Settings scene's `NSWindow` so the
/// appearance broadcasters (`WindowAppearanceSetter` + `GhosttyRuntime
/// .applyBackgroundColorToWindows`) can exclude it from the Ghostty
/// terminal-background stain. The Settings window keeps the stock
/// `NSColor.windowBackgroundColor` tone so its sidebar reads as a
/// standard macOS Settings pane instead of the terminal's theme color.
@MainActor
enum SettingsWindowTagger {
  /// Weak so the tracker releases naturally when the Settings window closes;
  /// the marker view re-registers on the next `viewDidMoveToWindow`.
  private(set) static weak var window: NSWindow?

  static func register(_ window: NSWindow) {
    Self.window = window
  }

  static func matches(_ candidate: NSWindow) -> Bool {
    candidate === Self.window
  }
}

/// Hosts a zero-size `NSView` whose `viewDidMoveToWindow` hook registers the
/// enclosing window with `SettingsWindowTagger`. Place once inside the
/// Settings scene content tree — no visual output.
struct SettingsWindowTag: NSViewRepresentable {
  func makeNSView(context: Context) -> TaggingView { TaggingView() }
  func updateNSView(_ nsView: TaggingView, context: Context) {}

  final class TaggingView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window {
        SettingsWindowTagger.register(window)
      }
    }
  }
}
