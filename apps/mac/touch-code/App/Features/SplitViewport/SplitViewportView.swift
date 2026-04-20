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
  let terminalEngine: TerminalEngine
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
  /// `HStack`/`VStack` + `@ViewBuilder` switch cases. Performance cost is
  /// negligible at the tree sizes this hierarchy sees (≤ 32 panels/tab).
  private func renderNode(_ node: SplitTree<PanelID>.Node, tab: TouchCodeCore.Tab) -> AnyView {
    switch node {
    case .leaf(let panelID):
      return AnyView(panelLeaf(panelID))
    case .split(let split):
      switch split.direction {
      case .horizontal:
        return AnyView(
          HStack(spacing: 1) {
            renderNode(split.left, tab: tab)
            renderNode(split.right, tab: tab)
          }
        )
      case .vertical:
        return AnyView(
          VStack(spacing: 1) {
            renderNode(split.left, tab: tab)
            renderNode(split.right, tab: tab)
          }
        )
      }
    }
  }

  @ViewBuilder
  private func panelLeaf(_ panelID: PanelID) -> some View {
    if let surface = terminalEngine.ghosttyRuntime?.surface(for: panelID) {
      PanelHostView(surface: surface)
        .background(Color.black)
    } else {
      // Missing surface — M5 will arrange lazy creation on tab activation.
      placeholderCell(panelID: panelID)
    }
  }

  private func placeholderCell(panelID: PanelID) -> some View {
    VStack {
      Text("Surface not yet created")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(panelID.description)
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}
