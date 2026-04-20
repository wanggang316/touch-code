import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// "Open in ▾" dropdown that lives on the Worktree header. Renders the built-in editor
/// allowlist + any custom entries, marks missing editors as disabled, and (on selection)
/// invokes `EditorClient.open` via an `EditorActionDispatcher`. A "Set as default for this
/// Project" sub-menu writes the per-Project override through `HierarchyClient`.
///
/// The feature reads its state from the root `EditorFeature`; the owning view passes in the
/// scoped store. The dropdown doesn't write any reducer state directly — it fires actions.
struct WorktreeHeaderOpenButton: View {
  @Bindable var store: StoreOf<EditorFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let worktreePath: String
  let onOpenResult: (Result<EditorChoice, EditorError>) -> Void

  @Dependency(EditorClient.self) private var editorClient
  @State private var openingEditor: EditorID?

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
          openEditor(descriptor.id)
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

  // MARK: - Actions

  private func openEditor(_ id: EditorID) {
    openingEditor = id
    let url = URL(fileURLWithPath: worktreePath)
    let projectID = self.projectID
    Task {
      do {
        let choice = try await editorClient.open(url, id, projectID)
        await MainActor.run {
          openingEditor = nil
          onOpenResult(.success(choice))
        }
      } catch let error as EditorError {
        await MainActor.run {
          openingEditor = nil
          onOpenResult(.failure(error))
        }
      } catch {
        await MainActor.run {
          openingEditor = nil
          onOpenResult(.failure(.spawnFailed(reason: String(describing: error))))
        }
      }
    }
  }

  // MARK: - Label

  private var currentDefaultLabel: String {
    // Prefer the per-Project override if set in the descriptor cache; otherwise global
    // default; otherwise Finder. The resolution here is visual; the live `open` call goes
    // through the full EditorClient.resolve chain.
    if openingEditor != nil { return "Opening…" }
    if let global = store.state.globalDefault,
       let match = store.state.descriptors.first(where: { $0.id == global }) {
      return "Open in \(match.displayName)"
    }
    return "Open in Finder"
  }
}
