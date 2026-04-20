import SwiftUI
import TouchCodeCore

@main
struct TouchCodeApp: App {
  @State private var bootstrap = AppBootstrap()

  var body: some Scene {
    WindowGroup {
      MainView()
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle("touch-code")
        .task { bootstrap.start() }
    }
    .windowStyle(.titleBar)
  }
}

/// Wires the shared `HookDispatcher` + `SocketServer` at app launch.
/// M3 scope: construct the IPC stack with a `FakeHookExecutor`; M3.1 /
/// follow-up milestones swap in the real `ProcessHookExecutor` and wire
/// the Runtime's `TerminalEngine.events()` stream via `attach(to:)`.
@MainActor
final class AppBootstrap {
  private var dispatcher: HookDispatcher?
  private var server: SocketServer?

  func start() {
    guard dispatcher == nil else { return }
    // Skip bootstrap under XCTest — tests build up their own isolated
    // harnesses (InMemoryIPCServer) and binding a shared Unix socket here
    // racing with parallel test runs makes the runner hang.
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return
    }
    let store = HookConfigStore()
    let config = (try? store.load()) ?? .empty
    let dispatcher = HookDispatcher(
      config: config,
      store: store,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )
    self.dispatcher = dispatcher

    let hookHandlers = HookHandlers(dispatcher: dispatcher, store: store)
    let systemHandlers = SystemHandlers(
      versions: .init(
        server: Self.bundleVersion(),
        appBundle: Self.bundleVersion()
      )
    )
    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers
    )
    let server = SocketServer(path: SocketPaths.resolve(), router: router)
    do {
      try server.start()
      self.server = server
    } catch {
      // Log-only: failing to bind the socket should not prevent the app
      // from opening its window. Users get a clear diagnostic via
      // `Console.app` and `tc system sockets`.
      print("SocketServer bind failed: \(error)")
    }
  }

  static func bundleVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
  }
}
