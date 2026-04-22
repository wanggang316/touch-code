import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Split button: left half opens the resolved default editor; right half
/// (caret) is the picker menu. Resolution, picker content, and the
/// "Set default for this Project" sub-menu all flow through the
/// `WorktreeHeaderFeature` delegate so `RootFeature` owns the editor-open
/// side effect and descriptors stay TCA-observable.
struct HeaderOpenSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Bindable var editorStore: StoreOf<EditorFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreePath: String
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    HStack(spacing: 0) {
      primary
      caret
    }
    .task { editorStore.send(.onAppear) }
  }

  // MARK: - Primary

  private var primary: some View {
    Button {
      store.send(
        .openDefaultEditorTapped(
          worktreePath: worktreePath,
          projectID: projectID
        ))
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.up.right.square")
          .accessibilityHidden(true)
        Text(primaryLabel)
          .lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(primaryLabel)
    .help(primaryLabel)
  }

  private var primaryLabel: String {
    switch resolvedDefault {
    case .editor(let descriptor): return "Open in \(descriptor.displayName)"
    case .finder: return "Open in Finder"
    }
  }

  private var resolvedDefault: EditorFeature.ResolvedDefault {
    EditorFeature.resolveDefault(
      projectOverride: projectOverrideID,
      globalDefault: editorStore.state.globalDefault,
      descriptors: editorStore.state.descriptors
    )
  }

  private var projectOverrideID: EditorID? {
    hierarchyManager.catalog
      .spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .defaultEditor
  }

  // MARK: - Caret menu

  private var caret: some View {
    Menu {
      openInMenu
      Divider()
      setDefaultMenu
      Divider()
      Button("+ Custom editors…") {
        store.send(.customEditorsTapped)
      }
    } label: {
      Image(systemName: "chevron.down")
        .font(.caption.bold())
        .accessibilityHidden(true)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel("Choose editor")
    .help("Choose editor")
  }

  @ViewBuilder
  private var openInMenu: some View {
    Section("Open in") {
      ForEach(editorStore.state.descriptors) { descriptor in
        Button {
          store.send(
            .openEditorTapped(
              editorID: descriptor.id,
              worktreePath: worktreePath,
              projectID: projectID
            ))
        } label: {
          HStack {
            Text(descriptor.displayName)
            if !descriptor.isInstalled {
              Text("(not installed)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        // Finder is a spec-hard "always enabled" entry; the `isInstalled` check on
        // `EditorRegistry.finder` currently returns true for `/usr/bin/open`, but we
        // refuse to rely on that invariant — the UI guards it explicitly.
        .disabled(!descriptor.isInstalled && descriptor.id != EditorFeature.finderEditorID)
        .help(
          descriptor.isInstalled || descriptor.id == EditorFeature.finderEditorID
            ? descriptor.displayName
            : "\(descriptor.displayName) is not installed")
      }
    }
  }

  @ViewBuilder
  private var setDefaultMenu: some View {
    Section("Set default for this Project") {
      Button("Use global default") {
        store.send(
          .setProjectDefaultEditorTapped(
            spaceID: spaceID,
            projectID: projectID,
            editorID: nil
          ))
      }
      Divider()
      ForEach(editorStore.state.descriptors.filter(\.isInstalled)) { descriptor in
        Button(descriptor.displayName) {
          store.send(
            .setProjectDefaultEditorTapped(
              spaceID: spaceID,
              projectID: projectID,
              editorID: descriptor.id
            ))
        }
      }
    }
  }
}
