import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Horizontal tab bar for the active Worktree. Reads `Worktree.tabs` from
/// the environment `HierarchyManager`; dispatches create / select / close
/// / rename / reorder / bulk-close actions through `TabBarFeature`.
///
/// Post M2-T2.7 the chip row lives inside `TabBarOverflowScroll`, which
/// owns horizontal scrolling, edge-gradient shadows, and auto-scroll-to-
/// selected; the trailing accessory cluster is pinned outside the scroll
/// region so `+` is always visible regardless of chip count.
struct TabBarView: View {
  let store: StoreOf<TabBarFeature>
  /// Resolved address of the active worktree whose tabs we render. If any
  /// of the IDs is nil, the view shows a thin empty bar.
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let activeTabID: TabID?
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    HStack(spacing: 4, content: barContent)
      .frame(height: TabBarMetrics.barHeight, alignment: .bottom)
  }

  @ViewBuilder
  private func barContent() -> some View {
    Group {
      if let worktree = currentWorktree() {
        TabBarOverflowScroll(activeTabID: activeTabID) {
          rowView(for: worktree)
        }
      }
      TabBarTrailingAccessories(
        onNewTab: {
          store.send(
            .newTabButtonTapped(
              inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
            ))
        }
      )
    }
  }

  @ViewBuilder
  private func rowView(for worktree: Worktree) -> some View {
    TabBarRowView(
      tabs: worktree.tabs,
      activeTabID: activeTabID,
      onSelect: { tabID in
        store.send(
          .tabButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onClose: { tabID in
        store.send(
          .closeButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onMiddleClick: { tabID in
        store.send(
          .middleClicked(
            tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onCloseOthers: { tabID in
        store.send(
          .contextMenuCloseOthers(
            tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onCloseToRight: { tabID in
        store.send(
          .contextMenuCloseToRight(
            tabID, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onCloseAll: {
        store.send(
          .contextMenuCloseAll(
            inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onRenameCommit: { tabID, newName in
        store.send(
          .renameSubmitted(
            tabID, name: newName,
            inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      },
      onReorder: { orderedIDs in
        store.send(
          .dragReorderEnded(
            orderedIDs: orderedIDs,
            inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
          ))
      }
    )
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
