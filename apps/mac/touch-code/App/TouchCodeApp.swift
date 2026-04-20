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
    let hookConfigStore = HookConfigStore()
    let config = (try? hookConfigStore.load()) ?? .empty
    let dispatcher = HookDispatcher(
      config: config,
      store: hookConfigStore,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )
    self.dispatcher = dispatcher

    // Hierarchy: load existing catalog or start empty. No GhosttyRuntime
    // wired in this bootstrap — M6 RPCs land against an in-memory
    // catalog (useful for `tc space create`-style scripting); M8 / a
    // future milestone will swap in a real `TerminalEngine` so
    // `terminal.*` RPCs reach live panels.
    let catalogStore = CatalogStore()
    let catalog = (try? catalogStore.load()) ?? Catalog()
    let hierarchyRuntime = FakeHierarchyRuntime()
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: hierarchyRuntime
    )

    let hookHandlers = HookHandlers(dispatcher: dispatcher, store: hookConfigStore)
    let systemHandlers = SystemHandlers(
      versions: .init(
        server: Self.bundleVersion(),
        appBundle: Self.bundleVersion()
      )
    )
    let hierarchyHandlers = HierarchyHandlers(manager: hierarchy)
    // TerminalHandlers has no input sink until a real GhosttyRuntime is
    // bound — terminal.sendInput / broadcastInput return .unsupported
    // until then, which is the right behavior for the M6 scripted flow.
    let terminalHandlers = TerminalHandlers(
      sink: nil,
      catalog: { hierarchy.catalog }
    )
    let externalEditor = ExternalEditor(catalog: { hierarchy.catalog })
    let openHandlers = SystemOpenHandlers(editor: externalEditor)

    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers,
      openHandlers: openHandlers
    )
    let server = SocketServer(path: SocketPaths.resolve(), router: router)
    do {
      try server.start()
      self.server = server
    } catch {
      print("SocketServer bind failed: \(error)")
    }
  }

  static func bundleVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
  }
}
