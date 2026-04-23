import AppKit
import SwiftUI
import TouchCodeCore

/// AppKit half of the dual-path appearance wiring. SwiftUI's `.preferredColorScheme`
/// doesn't reach AppKit-hosted surfaces (Metal-backed Ghostty views); this representable
/// pokes `NSApp.appearance` and each `NSApp.windows[n].appearance` so those surfaces and
/// the window chrome (title bar, traffic lights, shadow) re-render in sync with the
/// user's picker choice. `viewDidMoveToWindow` fires once per scene attachment so newly
/// opened windows pick up the current appearance at birth.
struct WindowAppearanceSetter: NSViewRepresentable {
  let preference: AppearancePreference

  func makeNSView(context: Context) -> AppearanceApplyingView {
    let view = AppearanceApplyingView()
    view.preference = preference
    return view
  }

  func updateNSView(_ nsView: AppearanceApplyingView, context: Context) {
    nsView.preference = preference
  }
}

final class AppearanceApplyingView: NSView {
  var preference: AppearancePreference = .system {
    didSet {
      guard preference != oldValue else { return }
      applyAppearance(reason: "preferenceChanged")
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance(reason: "viewDidMoveToWindow")
  }

  private func applyAppearance(reason: String) {
    guard window != nil else { return }
    let appearance = preference.appearance
    NSApp.appearance = appearance
    for window in NSApp.windows {
      window.appearance = appearance
      window.contentView?.needsLayout = true
      window.contentView?.needsDisplay = true
      window.invalidateShadow()
    }
    AppearanceDiagnostics.log(
      "app-appearance reason=\(reason) mode=\(preference.rawValue) "
        + "requested=\(appearance?.name.rawValue ?? "nil") "
        + "effective=\(NSApp.effectiveAppearance.name.rawValue) "
        + "windowCount=\(NSApp.windows.count)"
    )
  }
}
