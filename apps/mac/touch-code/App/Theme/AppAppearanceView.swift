import SwiftUI
import TouchCodeCore

/// Scene-root wrapper that pairs SwiftUI's `.preferredColorScheme` with the AppKit
/// `NSApp.appearance` poke emitted by `WindowAppearanceSetter`. Both paths are driven
/// from the same `AppearancePreference` read through the environment-injected
/// `SettingsStore`, so SwiftUI and AppKit stay in lock-step on every user toggle or
/// macOS appearance flip. Placed at the root of each scene so newly opened windows
/// inherit the current appearance at birth.
struct AppAppearanceView<Content: View>: View {
  let settingsStore: SettingsStore
  let content: Content

  init(settingsStore: SettingsStore, @ViewBuilder content: () -> Content) {
    self.settingsStore = settingsStore
    self.content = content()
  }

  var body: some View {
    let preference = settingsStore.settings.general.appearance
    content
      .preferredColorScheme(preference.colorScheme)
      .background {
        WindowAppearanceSetter(preference: preference)
      }
  }
}
