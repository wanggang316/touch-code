import SwiftUI

@main
struct TouchCodeApp: App {
  @State private var skillBanner = SkillVersionBanner.live()

  var body: some Scene {
    WindowGroup {
      MainView(skillBanner: skillBanner)
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle("touch-code")
        .task { skillBanner.check() }
    }
    .windowStyle(.titleBar)
  }
}
