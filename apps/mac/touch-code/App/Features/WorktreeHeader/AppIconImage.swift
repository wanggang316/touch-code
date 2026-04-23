import AppKit
import SwiftUI

/// SwiftUI image that resolves the macOS app icon for a given bundle
/// identifier via `NSWorkspace`. Falls back to a generic SF Symbol if the
/// bundle can't be located (app not installed, or shell editors without a
/// bundle id). Caller controls size through `.frame(...)`.
struct AppIconImage: View {
  let bundleIdentifier: String
  let fallbackSystemName: String

  var body: some View {
    if let nsImage = Self.resolve(bundleIdentifier: bundleIdentifier) {
      Image(nsImage: nsImage)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: fallbackSystemName)
    }
  }

  private static func resolve(bundleIdentifier: String) -> NSImage? {
    guard !bundleIdentifier.isEmpty,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }
}
