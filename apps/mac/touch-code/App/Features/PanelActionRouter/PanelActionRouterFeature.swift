import ComposableArchitecture
import Foundation
import TouchCodeCore
import os.log

/// Pure router reducer for `TerminalEvent.panelActionRequested`. Maps each
/// typed `PanelActionRequest` onto exactly one `HierarchyClient` closure —
/// the single place where libghostty-sourced tab/split intents meet the
/// catalog mutation layer.
///
/// State is empty by design: the router is a fan-out table, not a state
/// machine. Every error path (missing panel address, stale catalog, invalid
/// resize direction) is swallowed and logged; a race with teardown must
/// never crash the runtime callback thread. Composing the feature into
/// `RootFeature` lands in the 0008 integration task and is intentionally
/// out of scope here — this milestone only wires the type contract and the
/// dispatch table.
///
/// Two simplifications, recorded for the Decision Log:
/// - `PanelActionRequest.gotoSplit` currently collapses spatial directions
///   (up/down/left/right) onto the tree's previous/next neighbor order
///   (`SplitTree.focusTarget`). A real spatial walk needs frame geometry
///   the reducer does not own; upgrade later if users ask.
/// - `PanelActionRequest.toggleSplitZoom` reads the live catalog snapshot
///   to decide between `focusPanel` (zoom) and `unzoomTab` (unzoom). This
///   is a read-then-write pair — benign at user-keystroke cadence.
@Reducer
struct PanelActionRouterFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case requested(PanelID, PanelActionRequest)
    case delegate(Delegate)

    /// Parent-consumed delegate. `PresentTerminal` and
    /// `ToggleCommandPalette` are UI-level intents the root reducer owns;
    /// the router only lifts them onto a typed action so the parent can
    /// service them without re-decoding the ghostty action.
    enum Delegate: Equatable {
      case presentTerminalRequested(PanelID)
      case commandPaletteToggleRequested
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  private static let logger = Logger(
    subsystem: "com.touch-code.router", category: "panel"
  )

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .requested(let panelID, let request):
        return dispatch(panelID, request)
      case .delegate:
        return .none
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func dispatch(_ panelID: PanelID, _ request: PanelActionRequest) -> Effect<Action> {
    switch request {
    case .newTab:
      guard let address = hierarchyClient.addressOf(panelID) else {
        Self.logger.info("newTab: no address for panel \(panelID.raw.uuidString, privacy: .public)")
        return .none
      }
      _ = try? hierarchyClient.createTab(
        address.worktreeID, address.projectID, address.spaceID, nil
      )
      return .none

    case .closeTab(.this):
      guard let address = hierarchyClient.addressOf(panelID) else { return .none }
      try? hierarchyClient.closeTab(
        address.tabID, address.worktreeID, address.projectID, address.spaceID
      )
      return .none

    case .closeTab(.other):
      closeSiblingTabs(from: panelID, mode: .other)
      return .none

    case .closeTab(.right):
      closeSiblingTabs(from: panelID, mode: .right)
      return .none

    case .moveTab(let offset):
      guard let address = hierarchyClient.addressOf(panelID) else { return .none }
      try? hierarchyClient.moveTab(
        address.tabID, address.worktreeID, address.projectID, address.spaceID, offset
      )
      return .none

    case .gotoTab(let target):
      gotoTab(from: panelID, target: target)
      return .none

    case .newSplit(let direction):
      guard let address = hierarchyClient.addressOf(panelID) else { return .none }
      let catalog = hierarchyClient.snapshot()
      guard
        let sourcePanel = findPanel(
          panelID: panelID, tabID: address.tabID,
          worktreeID: address.worktreeID, projectID: address.projectID,
          spaceID: address.spaceID, in: catalog
        )
      else { return .none }
      let newDir = Self.splitDirection(for: direction)
      _ = try? hierarchyClient.splitPanel(
        panelID, newDir,
        address.tabID, address.worktreeID, address.projectID, address.spaceID,
        sourcePanel.workingDirectory, nil
      )
      return .none

    case .gotoSplit(let direction):
      gotoSplit(from: panelID, direction: direction)
      return .none

    case .resizeSplit(let direction, let amount):
      try? hierarchyClient.resizePanel(panelID, direction, amount)
      return .none

    case .equalizeSplits:
      guard let address = hierarchyClient.addressOf(panelID) else { return .none }
      try? hierarchyClient.equalizeTabSplits(
        address.tabID, address.worktreeID, address.projectID, address.spaceID
      )
      return .none

    case .toggleSplitZoom:
      toggleSplitZoom(panelID: panelID)
      return .none

    case .presentTerminal:
      return .send(.delegate(.presentTerminalRequested(panelID)))

    case .toggleCommandPalette:
      return .send(.delegate(.commandPaletteToggleRequested))
    }
  }

  // MARK: - Tab helpers

  /// Closes every tab in the source panel's Worktree that matches `mode`
  /// relative to the source's own tab. `.other` keeps only the current tab;
  /// `.right` keeps the current tab plus every tab to its left. Ordering is
  /// the catalog's natural tab-array order. Snapshots the catalog once so
  /// closes don't chase indexes as the array shrinks.
  private func closeSiblingTabs(from panelID: PanelID, mode: CloseTabMode) {
    guard let address = hierarchyClient.addressOf(panelID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let worktree = findWorktree(
        worktreeID: address.worktreeID, projectID: address.projectID,
        spaceID: address.spaceID, in: catalog
      )
    else { return }
    guard let currentIndex = worktree.tabs.firstIndex(where: { $0.id == address.tabID })
    else { return }

    let doomed: [TabID]
    switch mode {
    case .other:
      doomed = worktree.tabs.enumerated()
        .filter { $0.offset != currentIndex }
        .map { $0.element.id }
    case .right:
      doomed = worktree.tabs.suffix(from: currentIndex + 1).map(\.id)
    case .this:
      return // handled in dispatch.
    }
    for tabID in doomed {
      try? hierarchyClient.closeTab(
        tabID, address.worktreeID, address.projectID, address.spaceID
      )
    }
  }

  private func gotoTab(from panelID: PanelID, target: GotoTabTarget) {
    guard let address = hierarchyClient.addressOf(panelID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let worktree = findWorktree(
        worktreeID: address.worktreeID, projectID: address.projectID,
        spaceID: address.spaceID, in: catalog
      ),
      !worktree.tabs.isEmpty,
      let currentIndex = worktree.tabs.firstIndex(where: { $0.id == address.tabID })
    else { return }

    let count = worktree.tabs.count
    let targetIndex: Int
    switch target {
    case .previous:
      targetIndex = (currentIndex - 1 + count) % count
    case .next:
      targetIndex = (currentIndex + 1) % count
    case .last:
      targetIndex = count - 1
    case .index(let i):
      guard i >= 0, i < count else { return }
      targetIndex = i
    }
    guard targetIndex != currentIndex else { return }
    let targetTabID = worktree.tabs[targetIndex].id
    try? hierarchyClient.selectTab(
      targetTabID, address.worktreeID, address.projectID, address.spaceID
    )
  }

  // MARK: - Split helpers

  /// Maps ghostty's `NewSplitDirection` onto the SplitTree's `NewDirection`.
  /// Ghostty only carries an orientation (horizontal/vertical) so we pick a
  /// default insertion side: new panel appears to the right of the source
  /// for horizontal, below for vertical — matches the insertion semantics
  /// the existing split UI uses elsewhere in the app.
  private static func splitDirection(
    for direction: NewSplitDirection
  ) -> SplitTree<PanelID>.NewDirection {
    switch direction {
    case .horizontal: return .right
    case .vertical: return .down
    }
  }

  /// Resolves the target panel for `gotoSplit` and calls `focusPanel`.
  /// Simplification: every direction collapses onto the SplitTree's
  /// previous/next linearization. Up/left → previous, down/right → next.
  /// A real spatial walk needs per-panel frames the reducer does not see;
  /// revisit when the viewport layer exposes geometry.
  private func gotoSplit(from panelID: PanelID, direction: FocusDirection) {
    guard let address = hierarchyClient.addressOf(panelID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let tab = findTab(
        tabID: address.tabID, worktreeID: address.worktreeID,
        projectID: address.projectID, spaceID: address.spaceID, in: catalog
      )
    else { return }

    let treeDirection: SplitTree<PanelID>.FocusDirection
    switch direction {
    case .previous, .up, .left:
      treeDirection = .previous
    case .next, .down, .right:
      treeDirection = .next
    }
    guard let neighborID = tab.splitTree.focusTarget(for: treeDirection, from: panelID)
    else { return }
    try? hierarchyClient.focusPanel(
      neighborID, address.tabID, address.worktreeID, address.projectID, address.spaceID
    )
  }

  private func toggleSplitZoom(panelID: PanelID) {
    guard let address = hierarchyClient.addressOf(panelID) else { return }
    let catalog = hierarchyClient.snapshot()
    guard
      let tab = findTab(
        tabID: address.tabID, worktreeID: address.worktreeID,
        projectID: address.projectID, spaceID: address.spaceID, in: catalog
      )
    else { return }

    if tab.splitTree.zoomed == panelID {
      try? hierarchyClient.unzoomTab(
        address.tabID, address.worktreeID, address.projectID, address.spaceID
      )
    } else {
      try? hierarchyClient.focusPanel(
        panelID, address.tabID, address.worktreeID, address.projectID, address.spaceID
      )
    }
  }

  // MARK: - Catalog lookups

  private func findWorktree(
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID,
    in catalog: Catalog
  ) -> Worktree? {
    catalog.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  private func findTab(
    tabID: TabID,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID,
    in catalog: Catalog
  ) -> Tab? {
    findWorktree(
      worktreeID: worktreeID, projectID: projectID, spaceID: spaceID, in: catalog
    )?.tabs.first(where: { $0.id == tabID })
  }

  private func findPanel(
    panelID: PanelID,
    tabID: TabID,
    worktreeID: WorktreeID,
    projectID: ProjectID,
    spaceID: SpaceID,
    in catalog: Catalog
  ) -> Panel? {
    findTab(
      tabID: tabID, worktreeID: worktreeID, projectID: projectID,
      spaceID: spaceID, in: catalog
    )?.panels.first(where: { $0.id == panelID })
  }
}
