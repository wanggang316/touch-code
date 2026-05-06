import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore
import os
@preconcurrency import UserNotifications

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
  /// Tracks whether the sidebar list holds first-responder. `MainWindowCommands` reads it
  /// to gate destructive worktree chords (`⌘⌫` / `⌘⇧⌫`) so they only fire while the user
  /// is on the sidebar; when focus is in a Ghostty terminal pane the menu items are
  /// disabled and the chord falls through to the terminal.
  @State private var sidebarFocusObserver = SidebarFocusObserver()
  /// `SwiftUI.App` gives us no `applicationWillTerminate` hook on its own;
  /// the adaptor bridges AppKit's termination callback so we can flush
  /// debounced writes from `SettingsStore` before the process exits.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    // Single-instance main window. `Window(id:)` (vs. the previous
    // `WindowGroup`) ensures re-activating the dock icon brings the
    // existing window forward instead of spawning a duplicate, and the
    // system menu does not synthesize a "New Window" item that would let
    // users create extras out-of-band. See docs/design-docs/project-tags.md
    // §3.8 for the close-vs-quit semantics.
    Window("touch-code", id: TouchCodeApp.mainWindowID) {
      AppAppearanceView(settingsStore: appState.settingsStore) {
        if let store = appState.store, appState.terminalEngine != nil {
          ContentView(
            store: store,
            hierarchyManager: appState.hierarchyManager,
            settingsStore: appState.settingsStore,
            worktreeStatusMonitor: appState.worktreeStatusMonitor,
            notificationRollup: appState.notificationRollup,
            notificationStore: appState.notificationStore,
            osNotifier: appState.osNotifier
          )
          .frame(minWidth: 800, minHeight: 600)
          .environment(commandKeyObserver)
          .environment(\.resolvedShortcuts, appState.shortcutsStore.resolved)
        } else {
          // Initial loading state while appState.bringUp runs.
          // The view itself is intentionally cosmetic — bringUp is
          // kicked off from `.task` below, and the idempotency guard
          // (`store == nil` check inside bringUp) is load-bearing
          // because SwiftUI re-runs `.task` on scene reattach.
          AppBootstrapView()
            .frame(minWidth: 800, minHeight: 600)
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
      // `MainWindowCommands` is rendered unconditionally and reads
      // `appState.store` lazily. Wrapping the call in `if let store = appState.store { … }`
      // resolves once at scene build (when `bringUp()` has not yet run and the store is
      // nil); SwiftUI's `Commands` builder does not subsequently re-add the dropped commands
      // when the store materialises, leaving the entire File menu absent and unbinding ⌘O /
      // ⌘P / ⌘T / etc. for the rest of the session.
      //
      // We also intentionally do NOT add `CommandGroup(replacing: .newItem) {}` to suppress
      // ⌘N "New Window": with `Window(id:)` AppKit no longer synthesizes that item, and the
      // empty-replacing block has the surprising side effect of wiping out every
      // `CommandGroup(after: .newItem)` content from `MainWindowCommands`.
      MainWindowCommands(
        store: { appState.store },
        shortcuts: appState.shortcutsStore.resolved,
        sidebarFocus: sidebarFocusObserver
      )
      CommandGroup(replacing: .appSettings) {
        // Chord routes through the registry so a user override in Settings → Shortcuts
        // rebinds the menu item without restart. Default remains the AppKit-conventional ⌘,.
        Button("Settings…") {
          openWindow(id: TouchCodeApp.settingsWindowID)
        }
        .appKeyboardShortcut(.openSettings, in: appState.shortcutsStore.resolved)
      }
    }

    Window("Settings", id: TouchCodeApp.settingsWindowID) {
      AppAppearanceView(settingsStore: appState.settingsStore) {
        if let store = appState.settingsWindowStore {
          SettingsWindowView(
            store: store,
            settingsStore: appState.settingsStore,
            shortcutsStore: appState.shortcutsStore
          )
          .environment(appState.hierarchyManager)
          .environment(appState.settingsStore)
          .environment(appState.developerPaneDependencies)
          .environment(appState.osNotifier)
          .environment(\.resolvedShortcuts, appState.shortcutsStore.resolved)
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

  /// Scene id for the single main window.
  static let mainWindowID = "main"
}

/// AppKit delegate that flushes debounced writes on graceful termination
/// and gates ⌘Q with a confirmation when running terminal sessions exist.
/// The weak reference is set from the scene's `.task` after `AppState` has
/// been constructed — before that, `applicationWillTerminate` is a no-op,
/// which is fine because nothing has been written yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  weak var appState: AppState?

  override init() {
    super.init()
    // Wire up macOS notification banner click delegation. Without this, the
    // taps on banners are silently ignored — clicking would activate the app
    // (default behaviour) but our deeplink would never be parsed.
    UNUserNotificationCenter.current().delegate = self
  }

  nonisolated func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      appState?.flushAllPersistedState()
    }
  }

  /// Handles a banner click. Parses the deeplink the OSNotifier embedded
  /// in `userInfo["deeplink"]` and dispatches `RootFeature.focusHierarchyPath`
  /// against the live root store.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let deeplink = userInfo["deeplink"] as? String
    let source = deeplink
      .flatMap(URL.init(string:))
      .flatMap(Self.parseDeeplink(_:))
    completionHandler()
    Task { @MainActor in
      guard let source else { return }
      appState?.store?.send(.focusHierarchyPath(source))
    }
  }

  /// Allow banners to fire while the app is foreground (default macOS
  /// behaviour suppresses them). The detector already gates banner posting
  /// on "either app not frontmost OR pane not focused", so by the time we
  /// reach this delegate we already know the user can't see the source.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  /// `touch-code://focus?project=...&worktree=...&tab=...&pane=...`
  /// → `(projectID, worktreeID, tabID, paneID)`.
  nonisolated static func parseDeeplink(_ url: URL) -> InboxEntry.SourcePath? {
    guard url.scheme == "touch-code", url.host == "focus" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let items = Dictionary(
      uniqueKeysWithValues: components?.queryItems?.compactMap { item -> (String, String)? in
        guard let value = item.value else { return nil }
        return (item.name, value)
      } ?? []
    )
    guard let projectStr = items["project"], let projectUUID = UUID(uuidString: projectStr),
      let worktreeStr = items["worktree"], let worktreeUUID = UUID(uuidString: worktreeStr),
      let tabStr = items["tab"], let tabUUID = UUID(uuidString: tabStr),
      let paneStr = items["pane"], let paneUUID = UUID(uuidString: paneStr)
    else { return nil }
    return InboxEntry.SourcePath(
      projectID: ProjectID(raw: projectUUID),
      worktreeID: WorktreeID(raw: worktreeUUID),
      tabID: TabID(raw: tabUUID),
      paneID: PaneID(raw: paneUUID)
    )
  }

  /// `false` keeps the app running in the dock when ⌘W closes the main
  /// window — touch-code is a long-lived terminal host and an inadvertent
  /// close should not tear down running panes. Re-clicking the dock icon
  /// (or `open -a touch-code`) re-shows the window.
  nonisolated func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

}

/// Holds the shell-wide runtime objects. `AppState` lives for the duration
/// of the app; `bringUp()` constructs the full stack (including optional
/// `GhosttyRuntime` and the `SocketServer` IPC stack) and assembles the
/// TCA `Store` with live clients. Before `bringUp()` runs, `store` and
/// `terminalEngine` are nil — the app renders a loading placeholder.
@MainActor
@Observable
final class AppState {
  let hierarchyManager: HierarchyManager
  let settingsStore: SettingsStore
  let shortcutsStore: ShortcutsStore
  /// v1 notifications inbox owner; survives the full app lifetime so the
  /// debounced JSON write to `~/.config/touch-code/notifications.json` and
  /// the in-memory unread state outlive any individual scene transition.
  let notificationStore: NotificationStore
  /// Per-level roll-up derivation; views read `notificationRollup.current`
  /// to render indicators. Created in `bringUp` once `hierarchyManager`
  /// can be queried for focus state.
  private(set) var notificationRollup: RollupIndexProvider?
  /// Drains the engine's TerminalEvent stream into `notificationDetector`.
  /// Held so `flushAllPersistedState` / app shutdown can cancel it cleanly.
  @ObservationIgnored private var notificationDetectorTask: Task<Void, Never>?
  /// Mirrors `notificationStore.unreadCount` onto the macOS Dock tile badge
  /// via `withObservationTracking` re-registration.
  @ObservationIgnored private var dockBadgerTask: Task<Void, Never>?
  /// R1: re-marks unread entries as read whenever the user focuses the
  /// pane they belong to. Observes catalog focus state via Observation
  /// re-registration; held so shutdown can cancel cleanly.
  @ObservationIgnored private var focusReadMarkerTask: Task<Void, Never>?
  /// Live banner adapter; held so M5's Settings panel can call
  /// `requestAuthorization()` from the recovery button. Single instance
  /// per process — Settings panel reads via `@Environment` rather than
  /// spawning its own (each `init` re-runs setNotificationCategories
  /// on the shared center).
  @ObservationIgnored private(set) var osNotifier: UserNotificationsOSNotifier?
  private(set) var terminalEngine: TerminalEngine?
  private(set) var store: StoreOf<RootFeature>?
  /// Long-lived store for the Settings window scene. Built during `bringUp()` so the
  /// store — and its in-memory editor-pane state — survives open/close cycles of the
  /// window (spec M16).
  private(set) var settingsWindowStore: StoreOf<SettingsWindowFeature>?
  /// Shared dependency container for the Developer pane. Built at the tail
  /// of `bringUp()`; nil until then, which is why the Settings scene body
  /// renders a `ProgressView` placeholder.
  private(set) var developerPaneDependencies: DeveloperPaneDependencies?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?
  /// Per-Worktree "git status is non-clean" cache. The sidebar row's `.task(id:)`
  /// refreshes this lazily; a small dot is drawn next to the row name when dirty.
  let worktreeStatusMonitor: WorktreeStatusMonitor

  private var socketServer: SocketServer?
  // EditorClient is built inside bringUp() alongside the TCA dependency
  // wiring and then threaded into startIPC() so EditorHandlers and the
  // in-app reducer stack share a single service instance.
  private var editorClient: EditorClient?
  private var hierarchyClient: HierarchyClient?

  /// Master Terminal: app-level summon-by-hotkey panel that hosts a
  /// `claude remote-control` session. Wired in `bringUp()`. The controller
  /// + hotkey live for the app lifetime; the controller itself is lazy
  /// internally (no NSPanel constructed until first toggle).
  private var masterTerminalController: MasterTerminalController?
  private var masterTerminalHotkey: MasterTerminalHotkey?

  init() {
    let catalogStore = CatalogStore()
    let runtime = GhosttyBackedHierarchyRuntime()
    let catalog = (try? catalogStore.load()) ?? .empty

    let manager = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: runtime
    )

    self.catalogStore = catalogStore
    self.hierarchyRuntime = runtime
    self.hierarchyManager = manager
    self.settingsStore = SettingsStore()
    self.shortcutsStore = ShortcutsStore()
    self.notificationStore = NotificationStore()
    self.worktreeStatusMonitor = .live()
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

    // SettingsStore loads itself (with v1→v2 migration) during `init(fileURL:)`.

    let manager = hierarchyManager
    let settings = settingsStore

    // v1 notifications wiring — placed after `manager` is captured so the
    // detector closures can hold it. The detector consumes a fresh
    // `engine.events()` stream (broadcast-multi-consumer), so it runs in
    // parallel with RootFeature's own subscription.
    let osNotifier = UserNotificationsOSNotifier()
    self.osNotifier = osNotifier
    let detector = NotificationDetector(
      store: notificationStore,
      banner: osNotifier,
      catalogSnapshot: { manager.catalog },
      lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) }
    )
    let detectorEvents = engine.events()
    self.notificationDetectorTask = Task { @MainActor in
      for await event in detectorEvents {
        await detector.handle(event)
      }
    }
    let inbox = notificationStore
    DockBadger.setBadge(inbox.unreadCount)
    self.dockBadgerTask = Task { @MainActor in
      await Self.observeDockBadge(store: inbox)
    }

    // R1: clear unread on a pane when the user focuses it. Watches the
    // catalog's globally-focused pane id and calls markReadForPane on
    // every change. Idempotent at the store level — a re-fire with the
    // same pane is a no-op.
    self.focusReadMarkerTask = Task { @MainActor in
      await Self.observeFocusedPaneForRead(catalog: { manager.catalog }, lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) }, store: inbox)
    }

    // Roll-up provider — reads inbox + a hierarchy focus snapshot, recomputes
    // on either input changing. View sites observe its `.current` property.
    let rollup = RollupIndexProvider(
      store: inbox,
      focus: { [weak manager] in
        guard let manager else { return RollupFocusState() }
        return Self.focusState(from: manager.catalog, lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) })
      },
      observe: { [weak manager] in
        // Touch every Catalog field that participates in the focus
        // computation so withObservationTracking captures them. Reads
        // both top-level selection state and per-Project worktree
        // selection / expansion.
        guard let manager else { return }
        _ = manager.catalog.selectedProjectID
        for project in manager.catalog.projects {
          _ = project.selectedWorktreeID
          _ = project.isExpanded
          for worktree in project.worktrees {
            _ = worktree.selectedTabID
          }
        }
      }
    )
    self.notificationRollup = rollup

    // Build the editor + hierarchy clients once so the reducer stack AND the IPC
    // handlers share the exact same live instances — avoids two parallel
    // `LiveEditorService`s with divergent settings captures.
    let editor = EditorClient.live(settings: settings)
    let hierarchy = HierarchyClient.live(
      manager: manager,
      settings: settings,
      terminalClient: .live(engine: engine)
    )
    self.editorClient = editor
    self.hierarchyClient = hierarchy
    // SwiftUI views (e.g. `ProjectGeneralSettingsView`) read `@Dependency(SettingsWriter.self)`
    // directly; that resolution bypasses the per-store `withDependencies` overrides below and
    // would otherwise hit the `liveValue` `fatalError` placeholders. Install the live
    // implementations as the global defaults before any view body runs so View-side reads
    // find the wired instances. Reducer-side overrides on the Store layer on top of these.
    prepareDependencies {
      $0.editorClient = editor
      $0.hierarchyClient = hierarchy
      $0.settingsWriter = .live(settings)
      $0.terminalClient = .live(engine: engine)
    }
    // `SettingsWindowPresenter.open` forwards to the `OpenWindowAction` captured by the
    // main-window scene body into `openSettingsWindowAction`. SwiftUI's `OpenWindowAction`
    // must be read from a `View`'s environment so the reducer cannot hold it directly —
    // this indirection is what lets `RootFeature` trigger an open without pulling
    // `@Environment(\.openWindow)` into TCA.
    let presenter = SettingsWindowPresenter(
      open: { [weak self] in
        self?.openSettingsWindowAction?()
      },
      openAt: { [weak self] section in
        guard let self else { return }
        // Open the window first so the scene is visible / brought-to-front,
        // then push the selection into the settings store. The store
        // already exists by this point (built earlier in `bringUp`).
        self.openSettingsWindowAction?()
        self.settingsWindowStore?.send(.selectionChanged(section))
      }
    )
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
      $0.settingsWindowPresenter = presenter
      // Project Management: reconciler captures the live HierarchyClient so
      // `.reconcileDiscoveredWorktrees` (consumed from T-WORKTREE) flows
      // through the real manager binding. Default `now` is `Date.init`; tests
      // override with a scripted closure.
      $0.projectReconciler = ProjectReconciler(client: hierarchy)
    }

    self.settingsWindowStore = Store(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = editor
      $0.settingsWriter = .live(settings)
      $0.hierarchyClient = hierarchy
      $0[GhosttyTerminalSettingsClient.self] = .appLive()
    }

    startIPC(
      hierarchy: manager, editor: editor, hierarchyClient: hierarchy,
      settingsStore: settings
    )

    self.developerPaneDependencies = DeveloperPaneDependencies.live(
      settingsURL: Settings.defaultURL()
    )

    // Master Terminal: idempotent filesystem seed for ~/.config/touch-code/master-terminal/.
    // Failure to seed must not block app bring-up — the Master Terminal feature
    // simply won't have a working directory until the next launch.
    do {
      try MasterTerminalBootstrap.ensureUserDirectory()
    } catch {
      Logger.masterTerminal.error(
        "bootstrap failed: \(String(describing: error), privacy: .public)"
      )
    }

    // Master Terminal hotkey: ⌥⌘` toggles the slide-in panel. Hard-coded
    // for v1; promotion to ShortcutsStore deferred until that store grows
    // a "global hotkey" scope. See ExecPlan Decision Log D3.
    //
    // Skipped if GhosttyRuntime failed to initialise — without it the panel
    // would slide in empty, with no path to recover. The same guard already
    // gates the rest of the terminal stack at line 306.
    if let ghostty {
      let controller = MasterTerminalController(runtime: ghostty)
      self.masterTerminalController = controller
      self.masterTerminalHotkey = MasterTerminalHotkey(onTrigger: { [weak controller] in
        controller?.toggle()
      })
    }
  }

  /// Closure the main-window scene body installs to bridge TCA → `openWindow(id: "settings")`.
  /// Set from `.task { appState.openSettingsWindowAction = { openWindow(id: settingsWindowID) } }`
  /// inside `TouchCodeApp.body`. The presenter dependency captures `self` weakly and
  /// forwards `.open()` through this closure.
  @ObservationIgnored var openSettingsWindowAction: (@MainActor () -> Void)?

  /// Wires the SocketServer so `tc` CLI can talk to the running app.
  /// Skipped under XCTest — tests build their own in-memory harnesses and
  /// binding a shared Unix socket racing parallel runs makes the runner
  /// hang.
  private func startIPC(
    hierarchy: HierarchyManager,
    editor: EditorClient,
    hierarchyClient: HierarchyClient,
    settingsStore: SettingsStore
  ) {
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    {
      return
    }

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
    // Cancel notification background Tasks first so none can race the
    // final flush by mutating store state mid-write.
    notificationDetectorTask?.cancel()
    dockBadgerTask?.cancel()
    focusReadMarkerTask?.cancel()

    settingsStore.flush()
    shortcutsStore.flush()
    notificationStore.flush()
    catalogStore.flushPending()
  }

  /// Project the live `Catalog` plus `lastFocusedPane` lookup into a
  /// `FocusState` for `RollupIndex.compute`. Reads:
  /// - active project = `selectedProjectID`
  /// - active worktree = the active project's `selectedWorktreeID`
  /// - active tab = the active worktree's `selectedTabID`
  /// - focused pane = `lastFocusedPane(activeTabID)`
  /// - expanded projects = `Project.isExpanded` filtered to true
  static func focusState(
    from catalog: Catalog,
    lastFocusedPane: @MainActor (TabID) -> PaneID?
  ) -> RollupFocusState {
    let activeProject = catalog.projects.first(where: { $0.id == catalog.selectedProjectID })
    let activeWorktree = activeProject?.worktrees.first(where: { $0.id == activeProject?.selectedWorktreeID })
    let activeTab = activeWorktree?.tabs.first(where: { $0.id == activeWorktree?.selectedTabID })
    let focusedPane = activeTab.map { lastFocusedPane($0.id) } ?? nil
    let expanded = Set(catalog.projects.filter(\.isExpanded).map(\.id))

    return RollupFocusState(
      focusedPaneID: focusedPane,
      activeTabID: activeTab?.id,
      activeWorktreeID: activeWorktree?.id,
      activeProjectID: activeProject?.id,
      expandedProjectIDs: expanded
    )
  }

  /// Long-running R1 marker: every time the user focuses a different
  /// pane, mark its unread entries read. Drives off the same Observation
  /// re-arming pattern as the Dock badge mirror — each loop iteration
  /// reads the current focused pane id and re-arms a tracker that fires
  /// on any catalog mutation that could change that id (selectedProjectID
  /// / selectedWorktreeID / selectedTabID / lastFocusedPane).
  @MainActor
  private static func observeFocusedPaneForRead(
    catalog: @escaping @MainActor () -> Catalog,
    lastFocusedPane: @escaping @MainActor (TabID) -> PaneID?,
    store: NotificationStore
  ) async {
    while !Task.isCancelled {
      if let paneID = currentlyFocusedPane(catalog: catalog(), lastFocusedPane: lastFocusedPane) {
        store.markReadForPane(paneID)
      }
      let stream = AsyncStream<Void> { continuation in
        withObservationTracking {
          // Touch every catalog field the focused-pane composition reads
          // so any one of them mutating fires onChange.
          let snap = catalog()
          _ = snap.selectedProjectID
          for project in snap.projects {
            _ = project.selectedWorktreeID
            for worktree in project.worktrees {
              _ = worktree.selectedTabID
            }
          }
          // lastFocusedPane is read off HierarchyManager, which is
          // @Observable upstream — touching the resolved id here keeps
          // its observation registered alongside the catalog reads.
          if let activeProjectID = snap.selectedProjectID,
            let project = snap.projects.first(where: { $0.id == activeProjectID }),
            let worktreeID = project.selectedWorktreeID,
            let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
            let tabID = worktree.selectedTabID
          {
            _ = lastFocusedPane(tabID)
          }
        } onChange: {
          Task { @MainActor [continuation] in
            continuation.yield(())
          }
        }
        continuation.onTermination = { _ in }
      }
      for await _ in stream {
        break
      }
    }
  }

  /// Returns the single globally-focused pane id, computed the same way
  /// `NotificationDetector.globallyFocusedPane` does. Kept here so both
  /// the detector (drop-on-focus) and the R1 marker agree on the rule.
  /// Note: app frontmost is intentionally NOT gated here — focusing a
  /// pane in the app is the user's deliberate action regardless of
  /// frontmost state, and we want a worktree-switch to clear unreads on
  /// the newly-focused pane even if the user did it via a global hotkey
  /// while another app held foreground.
  static func currentlyFocusedPane(
    catalog: Catalog,
    lastFocusedPane: @MainActor (TabID) -> PaneID?
  ) -> PaneID? {
    guard let activeProjectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == activeProjectID }),
      let worktreeID = project.selectedWorktreeID,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let tabID = worktree.selectedTabID
    else { return nil }
    return lastFocusedPane(tabID)
  }

  /// Long-running mirror: pushes `store.unreadCount` to the Dock tile badge
  /// every time the count changes. Each loop iteration writes the *current*
  /// value before re-arming `withObservationTracking` so a burst of
  /// mutations between the previous `onChange` fire and the next arm
  /// settles to the final value rather than a stale one. Returns when
  /// the surrounding Task is cancelled.
  @MainActor
  private static func observeDockBadge(store: NotificationStore) async {
    while !Task.isCancelled {
      DockBadger.setBadge(store.unreadCount)
      let stream = AsyncStream<Void> { continuation in
        withObservationTracking {
          _ = store.unreadCount
        } onChange: {
          Task { @MainActor [continuation] in
            continuation.yield(())
          }
        }
        continuation.onTermination = { _ in }
      }
      for await _ in stream {
        break
      }
    }
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

  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) throws {
    _ = try engine?.ensureSurface(for: pane, in: worktree, env: env)
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
