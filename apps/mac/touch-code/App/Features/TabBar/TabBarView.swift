import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Horizontal tab bar for the active Worktree. Reads `Worktree.tabs` from
/// the environment `HierarchyManager`; dispatches create/select/close
/// actions through `TabBarFeature`.
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
    HStack(spacing: 4) {
      if let worktree = currentWorktree() {
        ForEach(worktree.tabs) { tab in
          tabButton(tab)
        }
      }
      Button {
        store.send(.newTabButtonTapped(
          inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
        ))
      } label: {
        Image(systemName: "plus")
          .accessibilityLabel("New Tab")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 6)
      Spacer()
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func currentWorktree() -> Worktree? {
    hierarchyManager.catalog.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  private func tabButton(_ tab: TouchCodeCore.Tab) -> some View {
    HStack(spacing: 4) {
      Button {
        store.send(.tabButtonTapped(
          tab.id, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
        ))
      } label: {
        Text(tab.name ?? "Tab")
          .lineLimit(1)
          .padding(.horizontal, 8)
      }
      .buttonStyle(.plain)
      Button {
        store.send(.closeButtonTapped(
          tab.id, inWorktree: worktreeID, inProject: projectID, inSpace: spaceID
        ))
      } label: {
        Image(systemName: "xmark")
          .font(.caption2)
          .accessibilityLabel("Close Tab")
      }
      .buttonStyle(.borderless)
      .opacity(0.6)
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 4)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(activeTabID == tab.id ? Color.accentColor.opacity(0.2) : Color.clear)
    )
  }
}
