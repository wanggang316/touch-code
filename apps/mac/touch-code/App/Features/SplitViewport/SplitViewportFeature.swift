import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Split viewport reducer. Actions mutate the active Tab's `SplitTree`
/// through `HierarchyClient`; live panel surfaces are created / destroyed
/// through `TerminalClient`. Per DEC-3 the state seeds `activeTabID:
/// TabID?` so M5's lazy-surface lifecycle can react to `.tabActivated`
/// without state restructuring.
@Reducer
struct SplitViewportFeature {
  @ObservableState
  struct State: Equatable {
    /// The Tab currently rendered in the viewport. Set by parent features
    /// (RootFeature selection stream in M4; lazy lifecycle in M5).
    var activeTabID: TabID?
    /// Lifecycle state for every panel currently rendered in the viewport.
    /// The view bridges catalog changes into this array via
    /// `.panelsInActiveTabChanged(_:)`; existing entries are preserved by
    /// `panelID` so a `.ready` surface does not get knocked back to
    /// `.loading` on an unrelated catalog mutation.
    var panelHosts: IdentifiedArrayOf<PanelHostFeature.State> = []
  }

  enum Action: Equatable {
    case activeTabChanged(TabID?)
    /// Emitted by `SplitViewportView` when the active Tab's panel list
    /// changes (panel opened, closed, split). The seeds carry the panel
    /// address; existing `panelHosts` entries with the same `panelID` are
    /// carried over unchanged.
    case panelsInActiveTabChanged([PanelHostFeature.State])
    case panelHosts(IdentifiedActionOf<PanelHostFeature>)
    case newPanelButtonTapped(
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID,
      workingDirectory: String)
    case splitButtonTapped(
      PanelID, direction: SplitTree<PanelID>.NewDirection,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID,
      workingDirectory: String)
    case closePanelButtonTapped(
      PanelID, inTab: TabID, inWorktree: WorktreeID,
      inProject: ProjectID, inSpace: SpaceID)
    case focusPanelRequested(
      PanelID, inTab: TabID, inWorktree: WorktreeID,
      inProject: ProjectID, inSpace: SpaceID)
    case resizeSplitRequested(
      SplitTree<PanelID>.Path, ratio: Double,
      inTab: TabID, inWorktree: WorktreeID, inProject: ProjectID, inSpace: SpaceID)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  /// Used to eager-attach warm ghostty surfaces when new panel seeds land —
  /// cuts the "Creating surface…" placeholder frame on tab / worktree
  /// switches when the surface already lives in the engine registry.
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .activeTabChanged(let tabID):
        state.activeTabID = tabID
        return .none

      case .panelsInActiveTabChanged(let seeds):
        let existing = state.panelHosts
        state.panelHosts = IdentifiedArray(
          uniqueElements: seeds.map { seed in
            if let carry = existing[id: seed.panelID] { return carry }
            // First time seeing this panel in state, but the surface may
            // already be warm from an earlier lifecycle (worktree revisit,
            // auto-seeded panel). Skip the `.loading → .ready` round-trip
            // so the view renders the live surface on the first frame.
            var seeded = seed
            if let surface = terminalClient.surface(seed.panelID) {
              seeded.phase = .ready
              seeded.surface = SurfaceBox(surface: surface)
            }
            return seeded
          }
        )
        return .none

      case .panelHosts:
        return .none

      case .newPanelButtonTapped(let tabID, let worktreeID, let projectID, let spaceID, let cwd):
        _ = try? hierarchyClient.openPanel(tabID, worktreeID, projectID, spaceID, cwd, nil)
        return .none

      case .splitButtonTapped(
        let panelID, let direction,
        let tabID, let worktreeID, let projectID, let spaceID, let cwd
      ):
        _ = try? hierarchyClient.splitPanel(
          panelID, direction, tabID, worktreeID, projectID, spaceID, cwd, nil
        )
        return .none

      case .closePanelButtonTapped(let panelID, let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.closePanel(panelID, tabID, worktreeID, projectID, spaceID)
        return .none

      case .focusPanelRequested(let panelID, let tabID, let worktreeID, let projectID, let spaceID):
        try? hierarchyClient.focusPanel(panelID, tabID, worktreeID, projectID, spaceID)
        return .none

      case .resizeSplitRequested(
        let path, let ratio,
        let tabID, let worktreeID, let projectID, let spaceID
      ):
        try? hierarchyClient.resizeSplit(path, ratio, tabID, worktreeID, projectID, spaceID)
        return .none
      }
    }
    .forEach(\.panelHosts, action: \.panelHosts) {
      PanelHostFeature()
    }
  }
}
