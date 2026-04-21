import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Repository General detail pane (spec M11): per-Project editor override and
/// worktree base directory override. Reads/writes through `HierarchyClient` per
/// design D1. `store` is scoped by `SettingsWindowView` before construction and
/// keyed by `projectID`; `descriptors` flows from the parent's `general` substate
/// so the picker renders the same editor list the global Default Editor pane shows.
struct RepositoryGeneralSettingsView: View {
  let projectID: ProjectID
  let store: StoreOf<RepositorySettingsFeature>
  let descriptors: [EditorDescriptor]

  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Editor override section
        VStack(alignment: .leading, spacing: 8) {
          Text("Default Editor")
            .font(.headline)
          if let project = projectInCatalog() {
            Picker(
              "Editor",
              selection: Binding<EditorID?>(
                get: { project.defaultEditor },
                set: { store.send(.setDefaultEditorOverride($0)) }
              )
            ) {
              Text("Use global default").tag(EditorID?(nil))
              Divider()
              ForEach(descriptors, id: \.id) { descriptor in
                Text(descriptor.displayName).tag(EditorID?(descriptor.id))
              }
            }
          }
        }

        // Worktree directory section
        VStack(alignment: .leading, spacing: 8) {
          Text("Worktree Base Directory")
            .font(.headline)
          if let project = projectInCatalog() {
            HStack {
              TextField(
                "Path",
                text: .constant(project.worktreesDirectory ?? "")
              )
              .disabled(true)

              Button("Choose") { chooseWorktreeDirectory() }
                .buttonStyle(.bordered)

              if project.worktreesDirectory != nil {
                Button("Clear") {
                  store.send(.setWorktreeBaseDirectory(nil))
                }
                .buttonStyle(.bordered)
              }
            }
          }
        }

        // Error banner — sticky until next successful write clears it.
        if let error = store.state.lastWriteFailure, !error.isEmpty {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundColor(.red)
            .padding(8)
            .background(Color(nsColor: .systemRed).opacity(0.1), in: .rect(cornerRadius: 6))
        }

        Spacer()
      }
      .padding(16)
    }
  }

  private func projectInCatalog() -> Project? {
    for space in hierarchyManager.catalog.spaces {
      if let project = space.projects.first(where: { $0.id == projectID }) {
        return project
      }
    }
    return nil
  }

  private func chooseWorktreeDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a directory for worktree storage"
    panel.begin { response in
      if response == .OK, let url = panel.urls.first {
        store.send(.setWorktreeBaseDirectory(url.path))
      }
    }
  }
}
