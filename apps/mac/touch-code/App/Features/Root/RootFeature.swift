import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Root reducer for the TCA shell. Composes sub-features for the sidebar,
/// the worktree detail column, and top-level presentations. Also owns the
/// two long-running subscriptions that every feature depends on:
///   - `terminalClient.events()` — drives crash / exit / output lifecycle
///   - `hierarchyClient.selectionChanges()` — drives worktree-scoped
///     features (C6 inbox filter, C7 diff viewer, M4 detail column swap)
///
/// Sub-feature Scopes for M3 (`HierarchySidebarFeature`) and M4
/// (`WorktreeDetailFeature`) are intentionally commented out — their state
/// types don't exist yet. The wiring is a one-line drop-in when they land.
@Reducer
struct RootFeature {
  @ObservableState
  struct State: Equatable {
    /// Most recent `HierarchySelection` seen from the stream. Features read
    /// this instead of holding a HierarchyManager reference.
    var selection: HierarchySelection = .empty

    /// Most recent engine event — diagnostic only in M2; M3/M4 features
    /// observe the stream directly via child-feature subscriptions.
    var lastEvent: LastEventMarker?

    /// M3 will replace with `HierarchySidebarFeature.State`.
    /// M4 will replace with `WorktreeDetailFeature.State`.
    /// `// @Presents var settingsSheet: SettingsFeature.State?` — reserved
    /// for C8 (DEC-4, M6 kickoff).
  }

  /// Opaque marker for diagnostic logging / tests — the full `TerminalEvent`
  /// is not Equatable (Data payloads in panelOutput), so we store a coarse
  /// discriminator.
  enum LastEventMarker: Equatable {
    case panelCreated
    case panelReady
    case panelOutput
    case panelExited
    case panelCrashed
    case panelClosedByTab
    case panelIdle
    case tabActivated
    case tabAutoClosed
    case worktreeActivated
    case hierarchyMutated

    init(_ event: TerminalEvent) {
      switch event {
      case .panelCreated: self = .panelCreated
      case .panelReady: self = .panelReady
      case .panelOutput: self = .panelOutput
      case .panelIdle: self = .panelIdle
      case .panelExited: self = .panelExited
      case .panelCrashed: self = .panelCrashed
      case .panelClosedByTab: self = .panelClosedByTab
      case .tabActivated: self = .tabActivated
      case .tabAutoClosed: self = .tabAutoClosed
      case .worktreeActivated: self = .worktreeActivated
      case .hierarchyMutated: self = .hierarchyMutated
      }
    }
  }

  enum Action: Equatable {
    case onLaunch
    case onQuit
    case selectionChanged(HierarchySelection)
    case engineEventReceived(LastEventMarker)
  }

  nonisolated enum CancelID: Sendable { case events, selectionChanges }

  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onLaunch:
        let eventStream = terminalClient.events()
        let selectionStream = hierarchyClient.selectionChanges()
        return .merge(
          .run { send in
            for await event in eventStream {
              await send(.engineEventReceived(LastEventMarker(event)))
            }
          }
          .cancellable(id: CancelID.events, cancelInFlight: true),

          .run { send in
            for await selection in selectionStream {
              await send(.selectionChanged(selection))
            }
          }
          .cancellable(id: CancelID.selectionChanges, cancelInFlight: true)
        )

      case .onQuit:
        return .merge(
          .cancel(id: CancelID.events),
          .cancel(id: CancelID.selectionChanges)
        )

      case .selectionChanged(let selection):
        state.selection = selection
        return .none

      case .engineEventReceived(let marker):
        state.lastEvent = marker
        return .none
      }
    }
  }
}
