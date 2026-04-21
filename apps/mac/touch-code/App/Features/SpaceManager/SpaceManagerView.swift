import ComposableArchitecture
import SwiftUI
import TouchCodeCore

struct SpaceManagerView: View {
  @Bindable var store: StoreOf<SpaceManagerFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let catalog = hierarchyManager.catalog

    NavigationStack {
      List {
        ForEach(catalog.spaces) { space in
          spaceRow(space, in: catalog)
        }
        .onMove { source, destination in
          store.send(.reordered(source, destination))
        }
      }
      .listStyle(.inset)
      .navigationTitle("Manage Spaces")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .confirmationDialog(
      removalTitle,
      isPresented: Binding(
        get: { store.pendingRemoval != nil },
        set: { if !$0 { store.send(.removeCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Space", role: .destructive) {
        store.send(.removeConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.removeCancelled)
      }
    } message: {
      Text(removalMessage)
    }
  }

  @ViewBuilder
  private func spaceRow(_ space: Space, in catalog: Catalog) -> some View {
    let isEditing = store.renameDraft?.spaceID == space.id
    let draftText = store.renameDraft?.text ?? ""

    HStack(spacing: 12) {
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      if isEditing {
        VStack(alignment: .leading, spacing: 4) {
          TextField(
            "Space name",
            text: Binding(
              get: { draftText },
              set: { store.send(.renameDraftChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .onSubmit { store.send(.renameCommitted) }
          .onExitCommand { store.send(.renameCancelled) }

          // Non-blocking duplicate-name warning
          let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
          let isDuplicate = trimmed.isEmpty ? false : catalog.spaces.contains {
            $0.id != space.id && $0.name == trimmed
          }
          if isDuplicate {
            Text("A Space with this name already exists.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Text(space.name)
          .onTapGesture {
            store.send(.renameRowTapped(space.id, currentName: space.name))
          }
          .accessibilityAddTraits(.isButton)
      }

      Spacer()

      Menu {
        Button {
          store.send(.renameRowTapped(space.id, currentName: space.name))
        } label: {
          Label("Rename", systemImage: "pencil")
        }

        Button(role: .destructive) {
          store.send(.removeTapped(space.id, name: space.name))
        } label: {
          Label("Remove", systemImage: "trash")
        }
        .disabled(catalog.spaces.count <= 1)
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Space options")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(isEditing)
    }
    .contentShape(Rectangle())
  }

  private var removalTitle: String {
    if let name = store.pendingRemoval?.displayName {
      return "Remove Space '\(name)'?"
    }
    return "Remove Space?"
  }

  private var removalMessage: String {
    guard let pending = store.pendingRemoval else { return "" }
    let projects = pending.projectCount == 1 ? "Project" : "Projects"
    let worktrees = pending.worktreeCount == 1 ? "Worktree" : "Worktrees"
    return """
    This will remove \(pending.projectCount) \(projects) and \(pending.worktreeCount) \(worktrees) from touch-code. \
    Files on disk are not affected.
    """
  }
}
