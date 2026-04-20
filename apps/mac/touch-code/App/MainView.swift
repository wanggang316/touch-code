import SwiftUI
import TouchCodeCore

@MainActor
@Observable
final class SingleSurfaceHost {
  enum Phase: Equatable {
    case loading
    case ready
    case failed(String)
  }

  private(set) var phase: Phase = .loading
  private(set) var panel: PanelSurface?
  private var runtime: GhosttyRuntime?
  private var bringUpStarted = false

  /// Spin up a GhosttyRuntime and a single PanelSurface. Idempotent:
  /// subsequent calls while loading or already ready are no-ops so SwiftUI
  /// re-running the .task doesn't leak a second runtime/surface pair.
  func bringUp() {
    guard !bringUpStarted else { return }
    bringUpStarted = true
    do {
      let runtime = try GhosttyRuntime()
      self.runtime = runtime
      let surface = try PanelSurface(
        runtime: runtime,
        panelID: PanelID(),
        workingDirectory: NSHomeDirectory()
      )
      runtime.register(panel: surface)
      self.panel = surface
      self.phase = .ready
    } catch {
      phase = .failed(friendlyMessage(for: error))
    }
  }

  /// Tear down the surface and drop the runtime. Safe to call multiple
  /// times; subsequent bringUp() calls will no-op because bringUpStarted
  /// is latched.
  func tearDown() {
    panel?.close()
    panel = nil
    runtime = nil
  }

  private func friendlyMessage(for error: any Error) -> String {
    if let err = error as? GhosttyError {
      switch err {
      case .configInitFailed:
        return "Couldn't load the libghostty configuration. Check ~/.config/ghostty/config for syntax errors."
      case .appInitFailed:
        return "libghostty failed to initialise. Try re-launching the app."
      case .surfaceInitFailed:
        return "Couldn't create a terminal surface. Metal may be unavailable on this display."
      }
    }
    return String(describing: error)
  }
}

struct MainView: View {
  @State private var host = SingleSurfaceHost()

  var body: some View {
    Group {
      switch host.phase {
      case .loading:
        VStack(spacing: 12) {
          ProgressView()
          Text("Starting libghostty \(GhosttyRuntime.info.version)…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .ready:
        if let panel = host.panel {
          PanelHostView(surface: panel)
            .background(Color.black)
        } else {
          EmptyView()
        }
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
    .onDisappear {
      host.tearDown()
    }
  }
}

#Preview {
  MainView()
}
