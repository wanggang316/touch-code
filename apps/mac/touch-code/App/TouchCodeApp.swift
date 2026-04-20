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
      if let store = appState.store {
        ContentView(
          store: store,
          hierarchyManager: appState.hierarchyManager,
          settingsStore: appState.settingsStore
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
  let settingsStore: SettingsStore
  private(set) var terminalEngine: TerminalEngine?
  private(set) var store: StoreOf<RootFeature>?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?

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
    // 0005 M6b: SettingsStore is constructed here so its `@Observable` surface is alive for
    // the full app lifetime. Views observe it through environment injection; the
    // EditorClient closes over it via .live(settings:hierarchy:) in bringUp().
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

    let manager = hierarchyManager
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
    }
  }

  /// Flushes all pending debounced writes. Called by `applicationWillTerminate`.
  func flushAllPersistedState() {
    settingsStore.flush()
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
