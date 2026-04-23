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

  /// Last scheme pushed to libghostty via `syncGhosttyScheme`. Skipping redundant
  /// pushes keeps AppKit's benign tick-driven `viewDidChangeEffectiveAppearance`
  /// calls from re-painting surfaces on every run-loop iteration.
  private var lastPushedGhosttyScheme: SwiftUI.ColorScheme?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyAppearance(reason: "viewDidMoveToWindow")
    syncGhosttyScheme(reason: "viewDidMoveToWindow")
  }

  /// AppKit-native hook that fires whenever the resolved appearance changes —
  /// covers both the manual preference toggle (via the `NSApp.appearance`
  /// cascade) and the macOS system dark-mode flip when preference is `.system`.
  /// Pushing from here is more reliable than `GhosttyColorSchemeSyncView`'s
  /// SwiftUI `onChange(of: \.colorScheme)`, which can miss system-level flips if
  /// the enclosing view body doesn't re-evaluate. Both paths coexist and are
  /// deduped by `lastPushedGhosttyScheme` + `setColorScheme`'s idempotency.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncGhosttyScheme(reason: "viewDidChangeEffectiveAppearance")
  }

  private func syncGhosttyScheme(reason: String) {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let scheme: SwiftUI.ColorScheme = isDark ? .dark : .light
    guard lastPushedGhosttyScheme != scheme else { return }
    lastPushedGhosttyScheme = scheme
    GhosttyRuntime.shared?.setColorScheme(scheme)
    AppearanceDiagnostics.log(
      "ghostty-scheme-sync reason=\(reason) "
        + "effective=\(effectiveAppearance.name.rawValue) "
        + "scheme=\(scheme == .dark ? "dark" : "light")"
    )
  }

  private func applyAppearance(reason: String) {
    guard window != nil else { return }
    let appearance = preference.appearance
    NSApp.appearance = appearance
    // Stain the NSWindow background with the ghostty theme color (read from
    // libghostty's config — falls back to `.windowBackgroundColor` before
    // the runtime is up). The sidebar's translucent material blends against
    // this layer via `withinWindow`, so the sidebar reads as the terminal's
    // tone rather than a flat system color. `GhosttyRuntime.setColorScheme`
    // covers the scheme-flip path; this one catches preference toggles.
    let ghosttyBackground = GhosttyRuntime.shared?.backgroundColor() ?? .windowBackgroundColor
    for window in NSApp.windows {
      window.appearance = appearance
      // Settings window opts out of the Ghostty terminal-background stain so
      // its sidebar reads as a standard macOS Settings pane. See
      // `SettingsWindowTagger`.
      window.backgroundColor =
        SettingsWindowTagger.matches(window) ? .windowBackgroundColor : ghosttyBackground
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
