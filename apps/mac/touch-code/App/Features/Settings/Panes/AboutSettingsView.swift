import SwiftUI

/// About detail pane. Reads every display string from `Bundle.main`'s Info.plist so there
/// is a single source of truth and so localisation / rebranding flows through the usual
/// build-setting machinery (design D2). Missing keys — including `NSHumanReadableCopyright`
/// — omit the corresponding line instead of substituting a constant, so absence is obvious
/// in Xcode when setting up a new build config.
struct AboutSettingsView: View {
  var body: some View {
    VStack(alignment: .center, spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 48))
        .foregroundStyle(.tint)
      Text(displayName).font(.title2.bold())
      if let versionLine = versionLine {
        Text(versionLine)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let copyright = copyright {
        Text(copyright)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Text("touch-code.app")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private var displayName: String {
    let info = Bundle.main.infoDictionary
    return (info?["CFBundleDisplayName"] as? String)
      ?? (info?["CFBundleName"] as? String)
      ?? "touch-code"
  }

  private var versionLine: String? {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    switch (short, build) {
    case (let s?, let b?): return "\(s) (Build \(b))"
    case (let s?, nil): return s
    case (nil, let b?): return "Build \(b)"
    case (nil, nil): return nil
    }
  }

  private var copyright: String? {
    Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
  }
}

#Preview {
  AboutSettingsView()
    .frame(width: 500, height: 300)
}
