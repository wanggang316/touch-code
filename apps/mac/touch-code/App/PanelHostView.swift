import AppKit
import SwiftUI
import TouchCodeCore

/// Hosts a `PanelSurface`'s `GhosttySurfaceView` inside SwiftUI.
///
/// The host view owns nothing; the `PanelSurface` has `@MainActor`
/// ownership of the underlying `ghostty_surface_t` and the `NSView`.
/// `makeNSView` returns the existing `GhosttySurfaceView`; `updateNSView`
/// is a no-op because the surface drives its own rendering via its Metal
/// layer — SwiftUI re-layout triggers the layout pass on the view which
/// then forwards size changes back to ghostty.
struct PanelHostView: NSViewRepresentable {
  let surface: PanelSurface

  func makeNSView(context: Context) -> GhosttySurfaceView {
    surface.view
  }

  func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
    // Nothing to do — ghostty renders on its own cadence.
  }
}
