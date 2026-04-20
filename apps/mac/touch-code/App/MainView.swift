import SwiftUI

struct MainView: View {
  let skillBanner: SkillVersionBanner

  var body: some View {
    VStack(spacing: 0) {
      SkillVersionBannerView(banner: skillBanner)
      Text("touch-code")
        .font(.largeTitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

#Preview {
  MainView(
    skillBanner: SkillVersionBanner(
      bundleVersionProvider: { "0.2.0" },
      installedVersionProvider: { _ in "0.1.0" }
    )
  )
}
