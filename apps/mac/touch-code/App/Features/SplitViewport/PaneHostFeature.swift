import ComposableArchitecture
import Foundation
import OSLog
import TouchCodeCore

private let paneHostLogger = Logger(subsystem: "com.touch-code.shell", category: "pane-host")

/// Lifecycle reducer for a single pane's `PaneSurface`. Owns the
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
struct PaneHostFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let paneID: PaneID
    let tabID: TabID
    let worktreeID: WorktreeID
    let projectID: ProjectID
    var phase: Phase = .loading
    /// Non-nil exactly when `phase == .ready`. Identity-equatable via
    /// `SurfaceBox`; the live surface is owned by `TerminalEngine`'s
    /// registry.
    var surface: SurfaceBox?

    var id: PaneID { paneID }

    enum Phase: Equatable {
      case loading
      case ready
      case failed(String)
    }
  }

  enum Action: Equatable {
    /// Fired from `LazyPaneHost.task`. Idempotent: registry short-circuit
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
    if let existing = terminalClient.surface(state.paneID) {
      state.phase = .ready
      state.surface = SurfaceBox(surface: existing)
      return
    }
    do {
      try terminalClient.ensureSurface(
        state.paneID, state.tabID, state.worktreeID, state.projectID
      )
    } catch {
      let message = String(describing: error)
      let paneIDDescription = state.paneID.description
      paneHostLogger.error(
        "ensureSurface failed for \(paneIDDescription, privacy: .public): \(message, privacy: .public)"
      )
      state.phase = .failed(message)
      state.surface = nil
      return
    }
    if let surface = terminalClient.surface(state.paneID) {
      state.phase = .ready
      state.surface = SurfaceBox(surface: surface)
    } else {
      let message = "Surface not registered after creation."
      let paneIDDescription = state.paneID.description
      paneHostLogger.warning(
        "\(message, privacy: .public) paneID=\(paneIDDescription, privacy: .public)"
      )
      state.phase = .failed(message)
      state.surface = nil
    }
  }
}

/// Identity-compared wrapper so `PaneSurface` (reference type, not
/// `Equatable`) can live in reducer state without leaking `===` semantics
/// through a global extension.
struct SurfaceBox: Equatable {
  let surface: PaneSurface
  static func == (lhs: SurfaceBox, rhs: SurfaceBox) -> Bool {
    lhs.surface === rhs.surface
  }
}
