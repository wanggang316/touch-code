import ComposableArchitecture
import Foundation
import OSLog
import TouchCodeCore

private let panelHostLogger = Logger(subsystem: "com.touch-code.shell", category: "panel-host")

/// Lifecycle reducer for a single panel's `PanelSurface`. Owns the
/// first-resolve, retry, and failure surfacing that used to live in a
/// SwiftUI view body. `@Dependency(TerminalClient.self)` sits here
/// (reducer-scoped, where `Store.withDependencies` in `bringUp()` actually
/// binds) rather than in the view, which otherwise would fall through to
/// `TerminalClient.liveValue`'s fatal-stub.
///
/// `terminalClient.ensureSurface` / `.surface` are synchronous `@MainActor`
/// closures, so the resolve path can mutate state directly — no `.run`
/// ceremony and no cancellation id to manage.
@Reducer
struct PanelHostFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let panelID: PanelID
    let tabID: TabID
    let worktreeID: WorktreeID
    let projectID: ProjectID
    let spaceID: SpaceID
    var phase: Phase = .loading
    /// Non-nil exactly when `phase == .ready`. Identity-equatable via
    /// `SurfaceBox`; the live surface is owned by `TerminalEngine`'s
    /// registry.
    var surface: SurfaceBox?

    var id: PanelID { panelID }

    enum Phase: Equatable {
      case loading
      case ready
      case failed(String)
    }
  }

  enum Action: Equatable {
    /// Fired from `LazyPanelHost.task`. Idempotent: registry short-circuit
    /// keeps re-renders free.
    case task
    case retryButtonTapped
  }

  @Dependency(TerminalClient.self) private var terminalClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .retryButtonTapped:
        state.phase = .loading
        state.surface = nil
        resolveSurface(state: &state)
        return .none
      case .task:
        resolveSurface(state: &state)
        return .none
      }
    }
  }

  private func resolveSurface(state: inout State) {
    if let existing = terminalClient.surface(state.panelID) {
      state.phase = .ready
      state.surface = SurfaceBox(surface: existing)
      return
    }
    do {
      try terminalClient.ensureSurface(
        state.panelID, state.tabID, state.worktreeID, state.projectID, state.spaceID
      )
    } catch {
      let message = String(describing: error)
      let panelIDDescription = state.panelID.description
      panelHostLogger.error(
        "ensureSurface failed for \(panelIDDescription, privacy: .public): \(message, privacy: .public)"
      )
      state.phase = .failed(message)
      state.surface = nil
      return
    }
    if let surface = terminalClient.surface(state.panelID) {
      state.phase = .ready
      state.surface = SurfaceBox(surface: surface)
    } else {
      let message = "Surface not registered after creation."
      let panelIDDescription = state.panelID.description
      panelHostLogger.warning(
        "\(message, privacy: .public) panelID=\(panelIDDescription, privacy: .public)"
      )
      state.phase = .failed(message)
      state.surface = nil
    }
  }
}

/// Identity-compared wrapper so `PanelSurface` (reference type, not
/// `Equatable`) can live in reducer state without leaking `===` semantics
/// through a global extension.
struct SurfaceBox: Equatable {
  let surface: PanelSurface
  static func == (lhs: SurfaceBox, rhs: SurfaceBox) -> Bool {
    lhs.surface === rhs.surface
  }
}
