import ComposableArchitecture
import SwiftUI
import TouchCodeCore

@main
struct TouchCodeApp: App {
  /// Single long-lived runtime stack. `@State` keeps this alive across the
  /// scene lifecycle without re-creating on re-render.
  @State private var appState = AppState()
  /// Agent skill version check — lazy banner that alerts if the skill
  /// installed for Claude Code / Codex / pi lags the bundled version
  /// (C5 plan 0004). Runs once on launch via `.task`.
  @State private var skillBanner = SkillVersionBanner.live()

  var body: some Scene {
    WindowGroup {
      if let store = appState.store {
        ContentView(
          store: store,
          hierarchyManager: appState.hierarchyManager
        )
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle("touch-code")
        .task { skillBanner.check() }
      } else {
        // Initial loading state while appState.bringUp runs.
        VStack(spacing: 12) {
          ProgressView()
          Text("Starting touch-code…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 800, minHeight: 600)
        // Idempotency guard on bringUp (store == nil check) is
        // load-bearing — SwiftUI re-runs .task on scene reattach.
        .task { appState.bringUp() }
      }
    }
    .windowStyle(.titleBar)
  }
}

/// Holds the shell-wide runtime objects. `AppState` lives for the duration
/// of the app; `bringUp()` constructs the full stack (including optional
/// `GhosttyRuntime` and the `SocketServer` + `HookDispatcher` IPC stack)
/// and assembles the TCA `Store` with live clients. Before `bringUp()`
/// runs, `store` and `terminalEngine` are nil — the app renders a loading
/// placeholder.
@MainActor
@Observable
final class AppState {
  let hierarchyManager: HierarchyManager
  private(set) var terminalEngine: TerminalEngine?
  private(set) var store: StoreOf<RootFeature>?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?

  // IPC stack (C3+C4): HookDispatcher + SocketServer + handlers.
  private var hookConfigStore: HookConfigStore?
  private var hookDispatcher: HookDispatcher?
  private var socketServer: SocketServer?

  init() {
    let catalogStore = CatalogStore()
    let runtime = GhosttyBackedHierarchyRuntime()
    let catalog = (try? catalogStore.load()) ?? .default
    let manager = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: runtime
    )
    self.catalogStore = catalogStore
    self.hierarchyRuntime = runtime
    self.hierarchyManager = manager
    // TerminalEngine is constructed in bringUp() once we know whether a
    // GhosttyRuntime is available — this avoids a throwaway engine.
  }

  /// Idempotent: subsequent calls while `store` is already set are no-ops.
  /// SwiftUI may re-run `.task` on scene transitions; the guard prevents
  /// rebuilding the engine + store and leaking the prior runtime.
  func bringUp() {
    guard store == nil else { return }
    let ghostty = try? GhosttyRuntime()
    self.ghosttyRuntime = ghostty
    let engine = TerminalEngine(
      store: catalogStore,
      hierarchy: hierarchyManager,
      ghosttyRuntime: ghostty
    )
    self.terminalEngine = engine
    hierarchyRuntime.attach(engine: engine)

    let manager = hierarchyManager
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = .live(manager: manager)
      $0.terminalClient = .live(engine: engine)
    }

    startIPC(hierarchy: manager)
  }

  /// Wires the HookDispatcher + SocketServer so `tc` CLI can talk to the
  /// running app. Uses `FakeHookExecutor` + `RecordingHookActionDispatcher`
  /// for M3 scope; M2.1.1+ wires the real `ProcessHookExecutor` and
  /// attaches to `engine.events()` via `HookDispatcher.attach(to:)`.
  /// Skipped under XCTest — tests build their own in-memory harnesses
  /// and binding a shared Unix socket racing parallel runs makes the
  /// runner hang.
  private func startIPC(hierarchy: HierarchyManager) {
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return
    }
    let hookConfigStore = HookConfigStore()
    self.hookConfigStore = hookConfigStore
    let config = (try? hookConfigStore.load()) ?? .empty
    let dispatcher = HookDispatcher(
      config: config,
      store: hookConfigStore,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )
    self.hookDispatcher = dispatcher

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
    // NOTE: `editor.*` app-side service is owned by exec-plan 0005 (C8);
    // this branch only ships the `tc open` CLI wrapper. After final
    // merge the router binds C8's EditorHandlers here.
    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers
    )
    let server = SocketServer(path: SocketPaths.resolve(), router: router)
    do {
      try server.start()
      self.socketServer = server
    } catch {
      print("SocketServer bind failed: \(error)")
    }
  }

  static func bundleVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
  }
}

/// Adapter: lets `HierarchyManager` call back into the engine for
/// lazy surface creation / teardown. `engine` is attached after the
/// manager is constructed to break the circular dependency.
@MainActor
final class GhosttyBackedHierarchyRuntime: HierarchyRuntime {
  private weak var engine: TerminalEngine?

  func attach(engine: TerminalEngine) {
    self.engine = engine
  }

  func ensureSurface(for panel: Panel, in worktree: Worktree) throws {
    _ = try engine?.ensureSurface(for: panel, in: worktree)
  }

  func closeSurface(for panelID: PanelID) {
    engine?.closeSurface(for: panelID)
  }
}
