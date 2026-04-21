import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Repository General detail pane (spec M11): per-Project editor override and
/// worktree base directory override. Reads/writes through `HierarchyClient` per
/// design D1. Signature and `projectID` parameter are frozen contracts.
struct RepositoryGeneralSettingsView: View {
  @Environment(\.hierarchyManager) var hierarchyManager
  @Environment(SettingsWindowFeature.self) var windowFeature
  @Environment(StoreOf<RepositorySettingsFeature>.self) var repositoryStore

  let projectID: ProjectID

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Editor override section
        VStack(alignment: .leading, spacing: 8) {
          Text("Default Editor")
            .font(.headline)
          if let project = projectInCatalog() {
            Picker("Editor", selection: Binding(
              get: { project.defaultEditor },
              set: { repositoryStore.send(.setDefaultEditorOverride($0)) }
            )) {
              Text("Use global default").tag(String?(nil))
              Divider()
              ForEach(windowFeature.general.descriptors, id: \.id) { descriptor in
                Text(descriptor.name).tag(String?(descriptor.id))
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
                text: Binding(
                  get: { project.worktreesDirectory ?? "" },
                  set: { _ in }
                )
              )
              .disabled(true)

              Button("Choose") {
                chooseWorktreeDirectory()
              }
              .buttonStyle(.bordered)

              if project.worktreesDirectory != nil {
                Button("Clear") {
                  repositoryStore.send(.setWorktreeBaseDirectory(nil))
                }
                .buttonStyle(.bordered)
              }
            }
          }
        }

        // Error banner
        if let error = repositoryStore.lastWriteFailure, !error.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "exclamationmark.circle.fill")
              .foregroundColor(.red)
          }
          .padding(8)
          .background(Color(nsColor: .systemRed).opacity(0.1), in: .rect(cornerRadius: 6))
        }

        Spacer()
      }
      .padding(16)
    }
  }

  private func projectInCatalog() -> Project? {
    let catalog = hierarchyManager.catalog
    for space in catalog.spaces {
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
        repositoryStore.send(.setWorktreeBaseDirectory(url.path))
      }
    }
  }
}

#Preview {
  RepositoryGeneralSettingsView(projectID: ProjectID())
    .frame(width: 500, height: 300)
}
