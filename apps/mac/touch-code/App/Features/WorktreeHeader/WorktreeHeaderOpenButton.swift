import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// "Open in ▾" dropdown on the Worktree header. Renders the built-in editor allowlist +
/// any custom entries, marks missing editors as disabled, and dispatches
/// `EditorFeature.Action.openRequested` through the reducer (0005 M6c: no more view-layer
/// `@Dependency(EditorClient)` so TestStore observes the full open path). A
/// "Set default for this Project" sub-menu routes through
/// `.setProjectOverride` / `.setProjectOverrideFailed`.
///
/// The current-default label reads the per-Project override from the catalog via the
/// injected `HierarchyManager`, falling back to the EditorFeature's cached global default,
/// then Finder.
struct WorktreeHeaderOpenButton: View {
  @Bindable var store: StoreOf<EditorFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let worktreePath: String
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    Menu {
      openInMenu
      Divider()
      setDefaultMenu
    } label: {
      HStack(spacing: 4) {
        Text(currentDefaultLabel)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .accessibilityHidden(true)
          .font(.caption.bold())
      }
    }
    .menuStyle(.borderlessButton)
    .help("Open this Worktree in an external editor")
    .task { store.send(.onAppear) }
  }

  // MARK: - Sub-menus

  @ViewBuilder
  private var openInMenu: some View {
    Section("Open in") {
      ForEach(store.state.descriptors) { descriptor in
        Button {
          store.send(.openRequested(
            editorID: descriptor.id,
            worktreePath: worktreePath,
            projectID: projectID
          ))
        } label: {
          row(for: descriptor)
        }
        .disabled(!descriptor.isInstalled)
      }
    }
  }

  @ViewBuilder
  private var setDefaultMenu: some View {
    Section("Set default for this Project") {
      Button {
        store.send(.setProjectOverride(
          projectID: projectID,
          spaceID: spaceID,
          editorID: nil
        ))
      } label: {
        Text("Use global default")
      }
      Divider()
      ForEach(store.state.descriptors.filter(\.isInstalled)) { descriptor in
        Button {
          store.send(.setProjectOverride(
            projectID: projectID,
            spaceID: spaceID,
            editorID: descriptor.id
          ))
        } label: {
          Text(descriptor.displayName)
        }
      }
    }
  }

  private func row(for descriptor: EditorDescriptor) -> some View {
    HStack {
      Text(descriptor.displayName)
      if !descriptor.isInstalled {
        Text("(not installed)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Label

  /// The dropdown label honours the full resolution chain: per-Project override →
  /// global default → Finder fallback. Reads the per-Project override directly from the
  /// environment `HierarchyManager` so the label tracks catalog mutations in real time;
  /// global default reads from the EditorFeature cache.
  private var currentDefaultLabel: String {
    if let override = projectOverrideID,
       let match = store.state.descriptors.first(where: { $0.id == override }) {
      return "Open in \(match.displayName)"
    }
    if let global = store.state.globalDefault,
       let match = store.state.descriptors.first(where: { $0.id == global }) {
      return "Open in \(match.displayName)"
    }
    return "Open in Finder"
  }

  private var projectOverrideID: EditorID? {
    hierarchyManager.catalog
      .spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .defaultEditor
  }
}
