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
  @Dependency(TerminalClient.self) private var terminalClient
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
                inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
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
              inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
            ))
        },
        onSplitRight: {
          store.send(
            .trailingSplitRequested(
              direction: .right,
              inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
            ))
        },
        onSplitDown: {
          store.send(
            .trailingSplitRequested(
              direction: .down,
              inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
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
      displayName: { tab, index in displayName(for: tab, index: index) },
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
      onRenameRequested: { tabID in
        guard let index = worktree.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = worktree.tabs[index]
        renameTarget = RenameTarget(
          id: tabID,
          currentName: displayName(for: tab, index: index + 1)
        )
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

  /// Resolves the display title for a tab. Priority:
  /// 1. `tab.name` — set only when the user has manually renamed the tab.
  /// 2. The focused pane's OSC `tabTitle` / `title` (libghostty pushes
  ///    these whenever the shell or a foreground program emits OSC 0/2).
  /// 3. The focused pane's `pwd` basename — a useful default when the
  ///    shell has not pushed a title yet.
  /// 4. `"Tab N"` where N is the 1-based position inside the worktree.
  ///
  /// Reads through `SurfaceInfo` (which is `@Observable`) so SwiftUI
  /// re-renders the chip when libghostty pushes a new title or the user
  /// changes directory. The focused pane id is read from
  /// `HierarchyManager.lastFocusedPane`; if the user has never focused a
  /// pane in the tab we fall back to the first leaf.
  private func displayName(for tab: TouchCodeCore.Tab, index: Int) -> String {
    if let name = tab.name, !name.isEmpty { return name }
    let paneID = hierarchyManager.lastFocusedPane(in: tab.id) ?? tab.panes.first?.id
    if let paneID, let info = terminalClient.surface(paneID)?.info {
      if let t = info.tabTitle, !t.isEmpty { return t }
      if let t = info.title, !t.isEmpty { return t }
      if let pwd = info.pwd {
        let basename = (pwd as NSString).lastPathComponent
        if !basename.isEmpty { return basename }
      }
    }
    return "Tab \(index)"
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }
}
