import AppKit
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
  /// `SwiftUI.App` gives us no `applicationWillTerminate` hook on its own;
  /// the adaptor bridges AppKit's termination callback so we can flush
  /// debounced writes from `SettingsStore`, `InboxStore`, and
  /// `NotificationSettingsStore` before the process exits.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      if let store = appState.store, appState.terminalEngine != nil {
        ContentView(
          store: store,
          hierarchyManager: appState.hierarchyManager,
          settingsStore: appState.settingsStore
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
        .task {
          appDelegate.appState = appState
          appState.bringUp()
        }
      }
    }
    .windowStyle(.titleBar)
  }
}

/// AppKit delegate that flushes debounced writes on graceful termination.
/// The weak reference is set from the scene's `.task` after `AppState` has
/// been constructed — before that, `applicationWillTerminate` is a no-op,
/// which is fine because nothing has been written yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var appState: AppState?

  nonisolated func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      appState?.flushAllPersistedState()
    }
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
  let settingsStore: SettingsStore
  private(set) var terminalEngine: TerminalEngine?
  private(set) var store: StoreOf<RootFeature>?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?
  private let inboxStore: InboxStore
  private let notificationSettingsStore: NotificationSettingsStore

  // IPC stack (C3+C4): HookDispatcher + SocketServer + handlers.
  private var hookConfigStore: HookConfigStore?
  private var hookDispatcher: HookDispatcher?
  private var socketServer: SocketServer?

  // C6 notification stack — constructed async after IPC stack in `bringUp()`.
  // Retained so `applicationWillTerminate` can call `flushPendingWrites()`
  // and `shutdown()`.
  var notificationBootstrap: C6AppBootstrap?

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
    // C6 stores — cheap to build up front so InboxClient.live has
    // stable referents to bind its closures to. The inbox + settings
    // files materialise during bringUp().
    // 0005 M6b: SettingsStore is constructed here so its `@Observable`
    // surface is alive for the full app lifetime. Views observe it via
    // env injection; EditorClient closes over it in bringUp().
    self.inboxStore = InboxStore()
    self.notificationSettingsStore = NotificationSettingsStore()
    self.settingsStore = SettingsStore()
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

    // Load C6 + C8 state — best-effort; decode errors are logged inside each
    // store and do not block the app from launching.
    _ = try? inboxStore.load()
    _ = try? notificationSettingsStore.load()
    // C7+C8 SettingsStore loads itself from disk during `init(fileURL:)`.

    let manager = hierarchyManager
    let inbox = inboxStore
    let notifSettings = notificationSettingsStore
    let settings = settingsStore
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = .live(manager: manager)
      $0.terminalClient = .live(engine: engine)
      // 0005 M6b critical wire: without these overrides, `EditorClient.liveValue` and
      // `SettingsWriter.liveValue` fatalError on any descendants call. Both factories close
      // over `settings` (global default + custom templates); `editorClient` additionally
      // closes over `manager` (per-Project override).
      $0.editorClient = .live(settings: settings, hierarchy: manager)
      $0.settingsWriter = .live(settings)
      $0[InboxClient.self] = .live(inbox: inbox, settings: notifSettings)
    }

    startIPC(hierarchy: manager)
    startNotifications(hierarchy: manager)
  }

  /// Async-launches the C6 notification stack. Skipped under XCTest (mirrors
  /// `startIPC`) and when `startIPC` was skipped or failed to bind (no
  /// `hookDispatcher` / `hookConfigStore` available). Retains the bootstrap
  /// on `self` so `applicationWillTerminate` can flush its debounced writes.
  private func startNotifications(hierarchy: HierarchyManager) {
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return
    }
    guard notificationBootstrap == nil,
          let dispatcher = hookDispatcher,
          let hookStore = hookConfigStore else { return }
    let inbox = inboxStore
    let settings = notificationSettingsStore
    Task { @MainActor [weak self] in
      do {
        let bootstrap = try await C6AppBootstrap.start(
          hierarchy: hierarchy,
          hookDispatcher: dispatcher,
          hookConfigStore: hookStore,
          settingsStore: settings,
          inboxStore: inbox,
          osNotifier: UserNotificationsOSNotifier(),
          badger: AppKitDockBadger(),
          permissionDelegate: NullPermissionDelegate()
        )
        self?.notificationBootstrap = bootstrap
      } catch {
        print("C6AppBootstrap.start failed: \(error)")
      }
    }
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

  /// Flushes all pending debounced writes. Called by `applicationWillTerminate`.
  /// Any debounced write that hasn't landed within 500 ms of quit would
  /// otherwise be dropped; each store below has its own debounce, so we
  /// drain them explicitly here.
  func flushAllPersistedState() {
    settingsStore.flush()
    try? inboxStore.saveNow()
    try? notificationSettingsStore.saveNow()
    try? notificationBootstrap?.flushPendingWrites()
    notificationBootstrap?.shutdown()
    // `CatalogStore` writes on scheduleSave and on app termination via its own signals.
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
