import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Renders the detail column for the selected Worktree: tab bar on top,
/// split viewport underneath. Both reach into the environment
/// `HierarchyManager` for catalog reads; neither duplicates state.
///
/// If `selection` does not resolve to a live Worktree (nil IDs, or IDs
/// that no longer exist after a prune), renders a neutral "Select a
/// Worktree" prompt.
struct WorktreeDetailView: View {
  @Bindable var store: StoreOf<WorktreeDetailFeature>
  let selection: HierarchySelection
  let terminalEngine: TerminalEngine
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    if let address = resolveAddress() {
      VStack(spacing: 0) {
        TabBarView(
          store: store.scope(state: \.tabBar, action: \.tabBar),
          spaceID: address.space,
          projectID: address.project,
          worktreeID: address.worktree,
          activeTabID: address.activeTab
        )
        if let tabID = address.activeTab {
          SplitViewportView(
            store: store.scope(state: \.splitViewport, action: \.splitViewport),
            spaceID: address.space,
            projectID: address.project,
            worktreeID: address.worktree,
            tabID: tabID,
            terminalEngine: terminalEngine
          )
        } else {
          emptyTab
        }
      }
    } else {
      placeholder
    }
  }

  private struct Address {
    let space: SpaceID
    let project: ProjectID
    let worktree: WorktreeID
    let activeTab: TabID?
  }

  private func resolveAddress() -> Address? {
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let space = hierarchyManager.catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else {
      return nil
    }
    return Address(
      space: spaceID,
      project: projectID,
      worktree: worktreeID,
      activeTab: worktree.selectedTabID
    )
  }

  private var emptyTab: some View {
    VStack(spacing: 12) {
      Text("No Tab selected")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text("Use the tab bar above to create a Tab.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var placeholder: some View {
    Text("Select a Worktree")
      .font(.title2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
