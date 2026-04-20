import ComposableArchitecture
import SwiftUI
import TouchCodeCore

@main
struct TouchCodeApp: App {
  /// Single long-lived runtime stack. `@State` keeps this alive across the
  /// scene lifecycle without re-creating on re-render. `GhosttyRuntime` is
  /// constructed lazily — if libghostty is unavailable (e.g. missing
  /// resources) the app still loads the TCA shell with no live surfaces.
  @State private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      if let store = appState.store {
        ContentView(
          store: store,
          hierarchyManager: appState.hierarchyManager,
          terminalEngine: appState.terminalEngine
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
        .task { appState.bringUp() }
      }
    }
    .windowStyle(.titleBar)
  }
}

/// Holds the shell-wide runtime objects. `AppState` lives for the duration
/// of the app; it constructs a single `HierarchyManager` + `TerminalEngine`
/// + (best-effort) `GhosttyRuntime` and binds the TCA `Store` with the
/// matching `liveValue` clients injected via `.withDependencies`.
@MainActor
@Observable
final class AppState {
  private(set) var hierarchyManager: HierarchyManager
  private(set) var terminalEngine: TerminalEngine
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
    let engine = TerminalEngine(store: catalogStore, hierarchy: manager)

    self.catalogStore = catalogStore
    self.hierarchyRuntime = runtime
    self.hierarchyManager = manager
    self.terminalEngine = engine
  }

  func bringUp() {
    guard store == nil else { return }
    // Best-effort libghostty bring-up. If it fails, the shell still loads
    // so the user sees the UI; surface creation will throw `runtimeUnavailable`.
    let ghostty = try? GhosttyRuntime()
    self.ghosttyRuntime = ghostty
    if let ghostty {
      self.terminalEngine = TerminalEngine(
        store: catalogStore,
        hierarchy: hierarchyManager,
        ghosttyRuntime: ghostty
      )
    }
    hierarchyRuntime.attach(engine: terminalEngine)

    let manager = hierarchyManager
    let engine = terminalEngine
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = .live(manager: manager)
      $0.terminalClient = .live(engine: engine)
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
