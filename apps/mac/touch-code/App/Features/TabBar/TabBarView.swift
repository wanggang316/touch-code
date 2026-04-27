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
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let activeTabID: TabID?
  @Environment(HierarchyManager.self) private var hierarchyManager
  /// Drives the rename sheet. Non-nil while the user is editing a tab's
  /// name; `RenameTarget` carries the seed `currentName` so the sheet can
  /// pre-populate without re-reading the catalog after the user has typed.
  @State private var renameTarget: RenameTarget?

  var body: some View {
    HStack(spacing: 4, content: barContent)
      .frame(height: TabBarMetrics.barHeight, alignment: .bottom)
      .sheet(item: $renameTarget) { target in
        TabRenameSheetView(
          initialName: target.currentName,
          onCommit: { newName in
            store.send(
              .renameSubmitted(
                target.id, name: newName,
                inWorktree: worktreeID, inProject: projectID
              ))
            renameTarget = nil
          },
          onCancel: { renameTarget = nil }
        )
      }
  }

  private struct RenameTarget: Identifiable, Equatable {
    let id: TabID
    let currentName: String
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
        activeTabSplitTree: activeSplitTree(),
        onNewTab: {
          store.send(
            .newTabButtonTapped(
              inWorktree: worktreeID, inProject: projectID
            ))
        },
        onSplitRight: {
          store.send(
            .trailingSplitRequested(
              direction: .right,
              inWorktree: worktreeID, inProject: projectID
            ))
        },
        onSplitDown: {
          store.send(
            .trailingSplitRequested(
              direction: .down,
              inWorktree: worktreeID, inProject: projectID
            ))
        }
      )
    }
  }

  /// Splits the active tab's tree for the trailing hover-preview popover.
  /// Returns `nil` when there is no active tab or the tab has no panes.
  private func activeSplitTree() -> SplitTree<PaneID>? {
    guard
      let worktree = currentWorktree(),
      let activeTabID,
      let tab = worktree.tabs.first(where: { $0.id == activeTabID })
    else { return nil }
    return tab.splitTree.isEmpty ? nil : tab.splitTree
  }

  @ViewBuilder
  private func rowView(for worktree: Worktree) -> some View {
    TabBarRowView(
      tabs: worktree.tabs,
      activeTabID: activeTabID,
      // Read through the @Observable HierarchyManager so any hook flip
      // of runningPanes triggers a chip re-render. Works against the
      // default-false stub on `.liveValue` / unconfigured clients.
      isDirty: { tabID in hierarchyManager.tabIsDirty(tabID) },
      onSelect: { tabID in
        store.send(
          .tabButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onClose: { tabID in
        store.send(
          .closeButtonTapped(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onMiddleClick: { tabID in
        store.send(
          .middleClicked(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCloseOthers: { tabID in
        store.send(
          .contextMenuCloseOthers(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCloseToRight: { tabID in
        store.send(
          .contextMenuCloseToRight(
            tabID, inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCloseAll: {
        store.send(
          .contextMenuCloseAll(
            inWorktree: worktreeID, inProject: projectID
          ))
      },
      onRenameRequested: { tabID in
        guard let tab = worktree.tabs.first(where: { $0.id == tabID }) else { return }
        renameTarget = RenameTarget(id: tabID, currentName: tab.name ?? "")
      },
      onReorder: { orderedIDs in
        store.send(
          .dragReorderEnded(
            orderedIDs: orderedIDs,
            inWorktree: worktreeID, inProject: projectID
          ))
      },
      onCacheLiveTitle: { tabID, title in
        // Direct manager call rather than a TCA action: the cache is a
        // persistence side-effect of rendering, not a user intent, so
        // routing through reducer + effect would add noise without
        // benefit. `setCachedTabTitle` debounces internally and no-ops
        // on identical values, so a hot OSC stream is cheap.
        hierarchyManager.setCachedTabTitle(
          title,
          for: tabID,
          in: worktreeID,
          in: projectID
        )
      }
    )
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
