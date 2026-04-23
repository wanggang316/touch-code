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
        AnyView(renderNode(root, path: SplitTree<PanelID>.Path(), tab: tab))
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
            workingDirectory: NSHomeDirectory()
          ))
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  /// Recursive renderer. Returns `AnyView` at every level to prevent
  /// SwiftUI's generic type inference from blowing up on nested splits
  /// (DEC-10). Performance cost is negligible at the tree sizes this
  /// hierarchy sees (≤ 32 panels/tab).
  ///
  /// Split nodes are rendered via `SplitView` — a `ZStack`-based splitter
  /// with a draggable divider. We intentionally do NOT use `HSplitView` /
  /// `VSplitView`: those wrap `NSSplitView`, which propagates Auto Layout
  /// constraint invalidations through every nested `NSHostingView`, and
  /// with multiple ghostty surfaces emitting `SurfaceInfo` changes on
  /// startup the reentrancy trips macOS's "more Update Constraints passes
  /// than there are views" exception. `SplitView` hard-sets frames and
  /// offsets on a `ZStack` instead — no Auto Layout ping-pong, and it
  /// honors `SplitTree.split.ratio` directly (`HSplitView` ignored it).
  ///
  /// `path` accumulates as we descend: `.left` for the first child, `.right`
  /// for the second. That's what `resizeSplitRequested` needs to locate the
  /// split node in the tree.
  private func renderNode(
    _ node: SplitTree<PanelID>.Node,
    path: SplitTree<PanelID>.Path,
    tab: TouchCodeCore.Tab
  ) -> AnyView {
    switch node {
    case .leaf(let panelID):
      return AnyView(panelLeaf(panelID))
    case .split(let split):
      let leftPath = SplitTree<PanelID>.Path(path.components + [.left])
      let rightPath = SplitTree<PanelID>.Path(path.components + [.right])
      let leftView = renderNode(split.left, path: leftPath, tab: tab)
      let rightView = renderNode(split.right, path: rightPath, tab: tab)
      let direction: SplitView<AnyView, AnyView>.Direction =
        split.direction == .horizontal ? .horizontal : .vertical
      let capturedPath = path
      let binding = Binding<CGFloat>(
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
      )
      return AnyView(
        SplitView(
          direction,
          binding,
          dividerColor: Color(nsColor: .separatorColor),
          left: { leftView },
          right: { rightView },
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
      )
    }
  }

  private func panelLeaf(_ panelID: PanelID) -> some View {
    Group {
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
}
