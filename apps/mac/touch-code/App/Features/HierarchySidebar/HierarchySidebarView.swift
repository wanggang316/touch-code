import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Renders `HierarchyManager.catalog` as a `List` with two levels of
/// disclosure groups (Space → Project → Worktree). Row taps fire actions
/// on `HierarchySidebarFeature`; structural data is read directly from the
/// environment `HierarchyManager` — TCA state holds only expansion sets
/// and routes commands.
///
/// The `currentSelection` parameter is read from the parent's
/// `RootFeature.State.selection` so rows can render selected state without
/// the sidebar feature itself subscribing to the selection stream.
struct HierarchySidebarView: View {
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  let currentSelection: HierarchySelection
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let spaces = hierarchyManager.catalog.spaces
    List {
      if spaces.isEmpty {
        emptyState
      } else {
        ForEach(spaces) { space in
          spaceSection(space)
        }
      }
    }
    .listStyle(.sidebar)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No Spaces yet")
        .font(.headline)
      Text("Creation UI ships in M6.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }

  private func spaceSection(_ space: Space) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { store.expandedSpaceIDs.contains(space.id) },
        set: { _ in store.send(.toggleSpaceExpansion(space.id)) }
      )
    ) {
      ForEach(space.projects) { project in
        projectSection(project, in: space)
      }
    } label: {
      Button {
        store.send(.spaceRowTapped(space.id))
      } label: {
        HStack {
          Image(systemName: "folder")
            .accessibilityHidden(true)
            .foregroundStyle(.secondary)
          Text(space.name).fontWeight(.semibold)
          Spacer()
        }
      }
      .buttonStyle(.plain)
      .listRowBackground(
        currentSelection.spaceID == space.id
          ? Color.accentColor.opacity(0.15) : Color.clear
      )
    }
  }

  private func projectSection(_ project: Project, in space: Space) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { store.expandedProjectIDs.contains(project.id) },
        set: { _ in store.send(.toggleProjectExpansion(project.id)) }
      )
    ) {
      ForEach(project.worktrees) { worktree in
        worktreeRow(worktree, in: project, space: space)
      }
    } label: {
      Button {
        store.send(.projectRowTapped(project.id, inSpace: space.id))
      } label: {
        HStack {
          Image(systemName: "square.stack.3d.up")
            .accessibilityHidden(true)
            .foregroundStyle(.secondary)
          Text(project.name)
          Spacer()
        }
      }
      .buttonStyle(.plain)
      .listRowBackground(
        currentSelection.projectID == project.id
          ? Color.accentColor.opacity(0.15) : Color.clear
      )
    }
  }

  private func worktreeRow(_ worktree: Worktree, in project: Project, space: Space) -> some View {
    Button {
      store.send(
        .worktreeRowTapped(worktree.id, inProject: project.id, inSpace: space.id)
      )
    } label: {
      HStack {
        Image(systemName: "arrow.triangle.branch")
          .accessibilityHidden(true)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading) {
          Text(worktree.name)
          if let branch = worktree.branch {
            Text(branch)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(
      currentSelection.worktreeID == worktree.id
        ? Color.accentColor.opacity(0.2) : Color.clear
    )
  }
}
