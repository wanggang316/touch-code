import SwiftUI

struct MainView: View {
  @State private var runtimeStatus: String = "Initialising…"
  @State private var ghosttyVersion: String = ""
  @State private var ghosttyMode: String = ""
  @State private var runtime: GhosttyRuntime?

  var body: some View {
    VStack(spacing: 12) {
      Text("touch-code")
        .font(.largeTitle)
      if !ghosttyVersion.isEmpty {
        Text("libghostty \(ghosttyVersion) (\(ghosttyMode))")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Text(runtimeStatus)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      let info = GhosttyRuntime.info
      ghosttyVersion = info.version
      ghosttyMode = info.buildMode
      do {
        runtime = try GhosttyRuntime()
        runtimeStatus = "Runtime ready ✓"
      } catch {
        runtimeStatus = "Runtime init failed: \(error)"
      }
    }
  }
}

#Preview {
  MainView()
}
