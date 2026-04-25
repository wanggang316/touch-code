import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

@main
struct TouchCodeApp: App {
  /// Single long-lived runtime stack. `@State` keeps this alive across the
  /// scene lifecycle without re-creating on re-render.
  @State private var appState = AppState()
  /// 0014: scene-wide ⌘ modifier observer, injected via `.environment`
  /// so any view (currently: the status-bar PR form) can swap hints when
  /// the user holds ⌘. The class self-installs its NSEvent monitor at
  /// `init` and tears down in `deinit`, so no explicit lifecycle calls
  /// are needed here.
  @State private var commandKeyObserver = CommandKeyObserver()
  /// `SwiftUI.App` gives us no `applicationWillTerminate` hook on its own;
  /// the adaptor bridges AppKit's termination callback so we can flush
  /// debounced writes from `SettingsStore` and `InboxStore` before the
  /// process exits. `settings.json` has a single writer (`SettingsStore`);
  /// consumers of notification preferences read through
  /// `NotificationSettingsReader`.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    WindowGroup {
      AppAppearanceView(settingsStore: appState.settingsStore) {
        if let store = appState.store, appState.terminalEngine != nil {
          ContentView(
            store: store,
            hierarchyManager: appState.hierarchyManager,
            settingsStore: appState.settingsStore,
            inboxStore: appState.inboxStore,
            worktreeStatusMonitor: appState.worktreeStatusMonitor
          )
          .frame(minWidth: 800, minHeight: 600)
          .environment(commandKeyObserver)
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
            appState.openSettingsWindowAction = {
              openWindow(id: TouchCodeApp.settingsWindowID)
            }
            appState.bringUp()
          }
        }
      }
    }
    .windowStyle(.titleBar)
    // Unified toolbar style lets the NavigationSplitView sidebar column's
    // material extend up under the traffic lights, matching Finder / Xcode.
    // Without this, the Ghostty-stained NSWindow background shows through
    // the titlebar area and the first List row visually overlaps with the
    // window controls.
    .windowToolbarStyle(.unified)
    .commands {
      if let store = appState.store {
        MainWindowCommands(store: store)
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          openWindow(id: TouchCodeApp.settingsWindowID)
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }

    Window("Settings", id: TouchCodeApp.settingsWindowID) {
      AppAppearanceView(settingsStore: appState.settingsStore) {
        if let store = appState.settingsWindowStore {
          SettingsWindowView(store: store, settingsStore: appState.settingsStore)
            .environment(appState.hierarchyManager)
            .environment(appState.settingsStore)
            .environment(appState.developerPaneDependencies)
        } else {
          // Settings window can be opened before AppState.bringUp completes (rare but
          // possible during launch). Render a transient placeholder; SwiftUI will
          // re-evaluate once the store lands.
          ProgressView().frame(minWidth: 750, minHeight: 500)
        }
      }
      .background(SettingsWindowTag())
    }
    .windowResizability(.contentMinSize)
  }

  /// Scene id for the Settings `Window`. Referenced from the app-menu Settings… command and
  /// from `SettingsWindowPresenter` overrides below.
  static let settingsWindowID = "settings"
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
  /// Long-lived store for the Settings window scene. Built during `bringUp()` so the
  /// store — and its in-memory editor-pane state — survives open/close cycles of the
  /// window (spec M16).
  private(set) var settingsWindowStore: StoreOf<SettingsWindowFeature>?
  /// Shared dependency container for the Developer pane (T3 — spec M6). Built
  /// at the tail of `bringUp()` once `hookConfigStore` is available so the
  /// pane's hook-reload closure captures the live store; nil until then, which
  /// is why the Settings scene body renders a `ProgressView` placeholder.
  private(set) var developerPaneDependencies: DeveloperPaneDependencies?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?
  /// Exposed to `ContentView` so the sidebar view can read
  /// `inbox.inbox` directly for unread-dot aggregation — matches the
  /// `HierarchyManager`-through-`@Environment` pattern the sidebar
  /// already uses for structural data.
  let inboxStore: InboxStore
  /// Per-Worktree "git status is non-clean" cache. The sidebar row's `.task(id:)`
  /// refreshes this lazily; a small dot is drawn next to the row name when dirty.
  let worktreeStatusMonitor: WorktreeStatusMonitor

  // IPC stack (C3+C4): HookDispatcher + SocketServer + handlers.
  private var hookConfigStore: HookConfigStore?
  private var hookDispatcher: HookDispatcher?
  private var socketServer: SocketServer?
  // EditorClient is built inside bringUp() alongside the TCA dependency
  // wiring and then threaded into startIPC() so EditorHandlers and the
  // in-app reducer stack share a single service instance.
  private var editorClient: EditorClient?
  private var hierarchyClient: HierarchyClient?

  // C6 notification stack — constructed async after IPC stack in `bringUp()`.
  // Retained so `applicationWillTerminate` can call `flushPendingWrites()`
  // and `shutdown()`.
  var notificationBootstrap: C6AppBootstrap?

  init() {
    let catalogStore = CatalogStore()
    let runtime = GhosttyBackedHierarchyRuntime()
    var catalog = (try? catalogStore.load()) ?? .default

    // First-run seed: if catalog is empty, create a "Personal" Space
    let needsSeed = catalog.spaces.isEmpty
    if needsSeed {
      let seed = Space(name: "Personal")
      catalog.spaces = [seed]
      catalog.selectedSpaceID = seed.id
    }

    let manager = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: runtime
    )

    // Drain legacy v1 Project overrides (`defaultEditor`, `worktreesDirectory`) before
    // constructing SettingsStore — the drained map is folded into `Settings.projects[pid]`
    // during the v2 → v3 `settings.json` migration. Empty map on a v2 catalog; mutative
    // on a v1 catalog (clears the two fields in-memory so the next save writes v2 shape).
    let legacyOverrides = manager.drainLegacyOverrides()

    // When drain captured any override, flush the v2 catalog synchronously BEFORE
    // SettingsStore's atomic v2→v3 rename commits: otherwise a crash between the two
    // writes would leave a v3 settings.json (no further migration) paired with a v1
    // catalog (re-decoded on next launch → drain emits the same overrides → migration
    // no longer consulted → data silently lost). Seed-only change still goes through
    // the debounced path since no migration depends on it.
    if !legacyOverrides.isEmpty {
      try? catalogStore.saveNow(manager.catalog)
    } else if needsSeed {
      catalogStore.scheduleSave(manager.catalog)
    }
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
    // Settings stores catalog-overrides as a closure so the v2 → v3
    // migration can fold them into `projects[pid]` top-level fields.
    // After migration the closure is never called again (subsequent
    // launches hit the strict v3 branch).
    self.settingsStore = SettingsStore(catalogOverrides: legacyOverrides)
    self.worktreeStatusMonitor = .live()
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
    // SettingsStore loads itself (with v1→v2 migration) during `init(fileURL:)`.

    let manager = hierarchyManager
    let inbox = inboxStore
    let settings = settingsStore
    // Build the editor + hierarchy clients once so the reducer stack AND the IPC
    // handlers share the exact same live instances — avoids two parallel
    // `LiveEditorService`s with divergent settings captures.
    let editor = EditorClient.live(settings: settings)
    let hierarchy = HierarchyClient.live(manager: manager)
    self.editorClient = editor
    self.hierarchyClient = hierarchy
    // `SettingsWindowPresenter.open` forwards to the `OpenWindowAction` captured by the
    // main-window scene body into `openSettingsWindowAction`. SwiftUI's `OpenWindowAction`
    // must be read from a `View`'s environment so the reducer cannot hold it directly —
    // this indirection is what lets `RootFeature` trigger an open without pulling
    // `@Environment(\.openWindow)` into TCA.
    let presenter = SettingsWindowPresenter(open: { [weak self] in
      self?.openSettingsWindowAction?()
    })
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = hierarchy
      $0.terminalClient = .live(engine: engine)
      // 0005 M6b critical wire: without these overrides, `EditorClient.liveValue` and
      // `SettingsWriter.liveValue` fatalError on any descendants call. Both factories close
      // over `settings` (global default + custom templates); `editorClient` additionally
      // closes over `manager` (per-Project override).
      $0.editorClient = editor
      $0.settingsWriter = .live(settings)
      $0[InboxClient.self] = .live(inbox: inbox, settings: settings)
      $0.settingsWindowPresenter = presenter
      // Project Management: reconciler captures the live HierarchyClient so
      // `.reconcileDiscoveredWorktrees` (consumed from T-WORKTREE) flows
      // through the real manager binding. Default `now` is `Date.init`; tests
      // override with a scripted closure.
      $0.projectReconciler = ProjectReconciler(client: hierarchy)
    }

    // T4: HookConfigStore must exist before `settingsWindowStore` so the Repository
    // Hooks pane's reducer closes over the same instance the IPC stack uses. Created
    // here (not inside startIPC) so XCTest builds — which skip startIPC — can still
    // back the settings window.
    let hookConfigStore = HookConfigStore()
    self.hookConfigStore = hookConfigStore

    self.settingsWindowStore = Store(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = editor
      $0.settingsWriter = .live(settings)
      $0.hierarchyClient = hierarchy
      $0[HookConfigClient.self] = .live(store: hookConfigStore)
      $0[GhosttyTerminalSettingsClient.self] = .appLive()
    }

    startIPC(
      hierarchy: manager, editor: editor, hierarchyClient: hierarchy,
      settingsStore: settings,
      hookConfigStore: hookConfigStore
    )
    startNotifications(hierarchy: manager)

    // Developer pane dependencies are built last so the HookConfigStore
    // instance (created inside `startIPC`) is threaded into the live hook
    // loader. Captured weakly so quitting the IPC stack doesn't keep a stale
    // reference.
    self.developerPaneDependencies = DeveloperPaneDependencies.live(
      hookStore: hookConfigStore,
      settingsURL: Settings.defaultURL(),
      hooksURL: HookConfig.defaultURL()
    )
  }

  /// Closure the main-window scene body installs to bridge TCA → `openWindow(id: "settings")`.
  /// Set from `.task { appState.openSettingsWindowAction = { openWindow(id: settingsWindowID) } }`
  /// inside `TouchCodeApp.body`. The presenter dependency captures `self` weakly and
  /// forwards `.open()` through this closure.
  @ObservationIgnored var openSettingsWindowAction: (@MainActor () -> Void)?

  /// Async-launches the C6 notification stack. Skipped under XCTest (mirrors
  /// `startIPC`) and when `startIPC` was skipped or failed to bind (no
  /// `hookDispatcher` / `hookConfigStore` available). Retains the bootstrap
  /// on `self` so `applicationWillTerminate` can flush its debounced writes.
  private func startNotifications(hierarchy: HierarchyManager) {
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    {
      return
    }
    guard notificationBootstrap == nil,
      let dispatcher = hookDispatcher,
      let hookStore = hookConfigStore
    else { return }
    let inbox = inboxStore
    let settings = settingsStore
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
  private func startIPC(
    hierarchy: HierarchyManager,
    editor: EditorClient,
    hierarchyClient: HierarchyClient,
    settingsStore: SettingsStore,
    hookConfigStore: HookConfigStore
  ) {
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    {
      return
    }
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
    let editorHandlers = EditorHandlers(
      editor: editor,
      hierarchy: hierarchyClient,
      settings: settingsStore
    )
    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers,
      editorHandlers: editorHandlers
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

  func ensureSurface(for pane: Pane, in worktree: Worktree) throws {
    _ = try engine?.ensureSurface(for: pane, in: worktree)
  }

  func closeSurface(for paneID: PaneID) {
    engine?.closeSurface(for: paneID)
  }

  func hasSurface(for paneID: PaneID) -> Bool {
    engine?.hasSurface(for: paneID) ?? false
  }

  func focusSurfaceView(for paneID: PaneID) {
    engine?.focusSurfaceView(for: paneID)
  }
}
