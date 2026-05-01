import SwiftUI
import TouchCodeCore

/// View-side mapping from the model-layer `ScriptTintColor` token to a
/// SwiftUI `Color`. Lives here so `TouchCodeCore` stays UI-framework-free
/// and every consumer (script editor, header split button, command
/// palette icons) shares one palette.
enum ScriptTintColorPalette {
  static func color(for tint: ScriptTintColor) -> Color {
    switch tint {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    case .blue: return .blue
    case .teal: return .teal
    case .purple: return .purple
    case .gray: return .gray
    }
  }
}
