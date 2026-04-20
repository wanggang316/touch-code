import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Recursively renders the active Tab's `SplitTree<PanelID>`. Leaves become
/// `PanelHostView(surface:)`; splits become `HSplitView` / `VSplitView` per
/// `SplitTree.Direction`. Surface lookup goes through `TerminalEngine` (not
/// TCA state) — the engine is the authoritative source for live
/// `PanelSurface` instances.
///
/// Empty-Tab UX: centered "No panels" placeholder with a "New Panel" button.
/// The Tab is never auto-closed by this view (M4 contract from exec plan).
struct SplitViewportView: View {
  let store: StoreOf<SplitViewportFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    if let tab = currentTab(), !tab.splitTree.isEmpty, let root = tab.splitTree.root {
      AnyView(renderNode(root, tab: tab))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      emptyPlaceholder
    }
  }

  private var emptyPlaceholder: some View {
    VStack(spacing: 12) {
      Text("No panels in this Tab")
        .font(.title3)
        .foregroundStyle(.secondary)
      Button("New Panel") {
        store.send(.newPanelButtonTapped(
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
    // LazyPanelHost owns the ensureSurface dance: first-appearance
    // creation via @Dependency(TerminalClient.self), registry lookup for
    // returning views, retry on failure.
    LazyPanelHost(
      panelID: panelID,
      spaceID: spaceID,
      projectID: projectID,
      worktreeID: worktreeID,
      tabID: tabID
    )
  }
}
