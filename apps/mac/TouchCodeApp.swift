import SwiftUI

@main
struct TouchCodeApp: App {
  var body: some Scene {
    WindowGroup {
      MainView()
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle("touch-code")
    }
    .windowStyle(.titleBar)
  }
}
