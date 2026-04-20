import SwiftUI
import TouchCodeCore

@MainActor
@Observable
final class SingleSurfaceHost {
  enum Status {
    case loading
    case ready(PanelSurface)
    case failed(String)
  }

  var status: Status = .loading
  private var runtime: GhosttyRuntime?

  func bringUp() {
    do {
      let runtime = try GhosttyRuntime()
      self.runtime = runtime
      let panel = try PanelSurface(
        runtime: runtime,
        panelID: PanelID(),
        workingDirectory: NSHomeDirectory()
      )
      runtime.register(panel: panel)
      status = .ready(panel)
    } catch {
      status = .failed(String(describing: error))
    }
  }
}

struct MainView: View {
  @State private var host = SingleSurfaceHost()

  var body: some View {
    Group {
      switch host.status {
      case .loading:
        VStack(spacing: 12) {
          ProgressView()
          Text("Starting libghostty \(GhosttyRuntime.info.version)…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .ready(let surface):
        PanelHostView(surface: surface)
          .background(Color.black)
      case .failed(let reason):
        VStack(spacing: 8) {
          Text("Runtime init failed")
            .font(.headline)
          Text(reason)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
      }
    }
    .task {
      host.bringUp()
    }
  }
}

#Preview {
  MainView()
}
