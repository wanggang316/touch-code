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
        AnyView(renderNode(root, tab: tab))
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
  /// SwiftUI's generic type inference from blowing up on nested
  /// `HSplitView`/`VSplitView` + `@ViewBuilder` switch cases (DEC-10).
  /// Performance cost is negligible at the tree sizes this hierarchy sees
  /// (≤ 32 panels/tab).
  ///
  /// Split containers use AppKit-backed `HSplitView` / `VSplitView` to get
  /// free drag-resize dividers; matches `resizeSplitRequested` action
  /// semantics without a custom `NSViewRepresentable`. Split ratio
  /// persistence via the dispatching action is a follow-up (the divider
  /// drag is observed only in AppKit today).
  private func renderNode(_ node: SplitTree<PanelID>.Node, tab: TouchCodeCore.Tab) -> AnyView {
    switch node {
    case .leaf(let panelID):
      return AnyView(panelLeaf(panelID))
    case .split(let split):
      switch split.direction {
      case .horizontal:
        return AnyView(
          HSplitView {
            renderNode(split.left, tab: tab)
            renderNode(split.right, tab: tab)
          }
        )
      case .vertical:
        return AnyView(
          VSplitView {
            renderNode(split.left, tab: tab)
            renderNode(split.right, tab: tab)
          }
        )
      }
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
