import ComposableArchitecture
import SwiftUI
import TouchCodeCore

@main
struct TouchCodeApp: App {
  /// Single long-lived runtime stack. `@State` keeps this alive across the
  /// scene lifecycle without re-creating on re-render.
  @State private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      if let store = appState.store, let engine = appState.terminalEngine {
        ContentView(
          store: store,
          hierarchyManager: appState.hierarchyManager,
          terminalEngine: engine
        )
        .frame(minWidth: 800, minHeight: 600)
        .navigationTitle("touch-code")
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
/// `GhosttyRuntime`) and assembles the TCA `Store` with live clients.
/// Before `bringUp()` runs, `store` and `terminalEngine` are nil — the app
/// renders a loading placeholder.
@MainActor
@Observable
final class AppState {
  let hierarchyManager: HierarchyManager
  private(set) var terminalEngine: TerminalEngine?
  private(set) var store: StoreOf<RootFeature>?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?
  private let inboxStore: InboxStore
  private let settingsStore: SettingsStore

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
    self.inboxStore = InboxStore()
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

    // Load C6 state — best-effort; decode errors are logged inside each
    // store and do not block the app from launching.
    _ = try? inboxStore.load()
    _ = try? settingsStore.load()

    let manager = hierarchyManager
    let inbox = inboxStore
    let settings = settingsStore
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = .live(manager: manager)
      $0.terminalClient = .live(engine: engine)
      $0[InboxClient.self] = .live(inbox: inbox, settings: settings)
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

  func ensureSurface(for panel: Panel, in worktree: Worktree) throws {
    _ = try engine?.ensureSurface(for: panel, in: worktree)
  }

  func closeSurface(for panelID: PanelID) {
    engine?.closeSurface(for: panelID)
  }
}
