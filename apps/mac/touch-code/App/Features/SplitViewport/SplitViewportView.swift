import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Recursively renders the active Tab's `SplitTree<PanelID>`. Leaves scope
/// a child `StoreOf<PanelHostFeature>` off the parent store and hand it
/// to `LazyPanelHost`; splits become `HSplitView` / `VSplitView` per
/// `SplitTree.Direction`. Surface lifecycle is owned entirely by
/// `PanelHostFeature`; this view only bridges catalog changes into the
/// reducer via `.panelsInActiveTabChanged(_:)`.
///
/// Empty-Tab UX: centered "No panels" placeholder with a "New Panel" button.
/// The Tab is never auto-closed by this view (M4 contract from exec plan).
struct SplitViewportView: View {
  @Bindable var store: StoreOf<SplitViewportFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    Group {
      if let tab = currentTab(), !tab.splitTree.isEmpty, let root = tab.splitTree.root {
        SubtreeView(
          node: root,
          path: SplitTree<PanelID>.Path(),
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
          spaceID: spaceID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        emptyPlaceholder
      }
    }
    .task(id: currentPanelSeedsKey()) {
      syncPanelHosts()
    }
  }

  private var emptyPlaceholder: some View {
    VStack(spacing: 12) {
      Text("No panels in this Tab")
        .font(.title3)
        .foregroundStyle(.secondary)
      Button("New Panel") {
        store.send(
          .newPanelButtonTapped(
            inTab: tabID, inWorktree: worktreeID,
            inProject: projectID, inSpace: spaceID,
            workingDirectory: currentWorktreePath() ?? NSHomeDirectory()
          ))
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Looks up the current Worktree's absolute path from the catalog so the
  /// fallback "New Panel" button spawns a terminal rooted at the Worktree
  /// directory. Returns nil if the Worktree has been pruned between render
  /// and tap — the caller falls back to `$HOME`.
  private func currentWorktreePath() -> String? {
    hierarchyManager.catalog
      .spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })?
      .path
  }

  private func currentTab() -> TouchCodeCore.Tab? {
    hierarchyManager.catalog.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })?
      .tabs.first(where: { $0.id == tabID })
  }

  /// Stable identity for `.task(id:)`: if the panel set (in order) is the
  /// same, SwiftUI won't re-fire the sync. Using the id collection directly
  /// is cheap — tabs hold ≤ ~32 panels.
  private func currentPanelSeedsKey() -> [PanelID] {
    currentTab()?.panels.map(\.id) ?? []
  }

  private func syncPanelHosts() {
    guard let tab = currentTab() else {
      store.send(.panelsInActiveTabChanged([]))
      return
    }
    let seeds = tab.panels.map { panel in
      PanelHostFeature.State(
        panelID: panel.id,
        tabID: tabID,
        worktreeID: worktreeID,
        projectID: projectID,
        spaceID: spaceID
      )
    }
    store.send(.panelsInActiveTabChanged(seeds))
  }

}

/// Recursive subtree renderer. Implemented as a concrete `struct` (not an
/// `AnyView`-returning function) so SwiftUI can diff identity across re-renders
/// — otherwise every divider drag tears down and rebuilds every `PanelHostView`,
/// causing the ghostty surface to re-mount on each frame and visibly flicker.
/// Self-recursion through a named type collapses the view-type tree to a single
/// `SubtreeView` at each level, sidestepping the generic-inference explosion
/// that originally motivated `AnyView`.
///
/// Split nodes are rendered via `SplitView` — a `ZStack`-based splitter with a
/// draggable divider. We intentionally do NOT use `HSplitView`/`VSplitView`:
/// those wrap `NSSplitView`, which propagates Auto Layout constraint
/// invalidations through every nested `NSHostingView`, and with multiple ghostty
/// surfaces emitting `SurfaceInfo` changes on startup the reentrancy trips
/// macOS's "more Update Constraints passes than there are views" exception.
/// `SplitView` hard-sets frames and offsets on a `ZStack` instead — no Auto
/// Layout ping-pong, and it honors `SplitTree.split.ratio` directly.
///
/// `path` accumulates as we descend: `.left` for the first child, `.right` for
/// the second. That's what `resizeSplitRequested` needs to locate the split
/// node in the tree.
private struct SubtreeView: View {
  let node: SplitTree<PanelID>.Node
  let path: SplitTree<PanelID>.Path
  let store: StoreOf<SplitViewportFeature>
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID
  let spaceID: SpaceID

  var body: some View {
    switch node {
    case .leaf(let panelID):
      LeafView(panelID: panelID, store: store)
    case .split(let split):
      splitBody(split)
    }
  }

  private func splitBody(_ split: SplitTree<PanelID>.Split) -> some View {
    let leftPath = SplitTree<PanelID>.Path(path.components + [.left])
    let rightPath = SplitTree<PanelID>.Path(path.components + [.right])
    let direction: SplitView<SubtreeView, SubtreeView>.Direction =
      split.direction == .horizontal ? .horizontal : .vertical
    let capturedPath = path
    return SplitView(
      direction,
      Binding<CGFloat>(
        get: { CGFloat(split.ratio) },
        set: { newRatio in
          store.send(
            .resizeSplitRequested(
              capturedPath,
              ratio: Double(newRatio),
              inTab: tabID,
              inWorktree: worktreeID,
              inProject: projectID,
              inSpace: spaceID
            ))
        }
      ),
      dividerColor: Color(nsColor: .separatorColor),
      left: {
        SubtreeView(
          node: split.left,
          path: leftPath,
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
          spaceID: spaceID
        )
      },
      right: {
        SubtreeView(
          node: split.right,
          path: rightPath,
          store: store,
          tabID: tabID,
          worktreeID: worktreeID,
          projectID: projectID,
          spaceID: spaceID
        )
      },
      onEqualize: {
        store.send(
          .resizeSplitRequested(
            capturedPath,
            ratio: 0.5,
            inTab: tabID,
            inWorktree: worktreeID,
            inProject: projectID,
            inSpace: spaceID
          ))
      }
    )
  }
}

private struct LeafView: View {
  let panelID: PanelID
  let store: StoreOf<SplitViewportFeature>

  var body: some View {
    if let childStore = store.scope(
      state: \.panelHosts[id: panelID],
      action: \.panelHosts[id: panelID]
    ) {
      LazyPanelHost(store: childStore)
    } else {
      // One-frame gap between panel entering the catalog and the sync
      // action landing `panelHosts[id: panelID]` in state. Render a
      // neutral placeholder rather than blanking the pane.
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
  }
}
