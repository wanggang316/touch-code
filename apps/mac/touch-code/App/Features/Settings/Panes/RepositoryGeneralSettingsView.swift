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
    Form {
      if let project = projectInCatalog() {
        Section("Default Editor") {
          Picker(
            "Editor",
            selection: Binding<EditorID?>(
              get: { project.defaultEditor },
              set: { store.send(.setDefaultEditorOverride($0)) }
            )
          ) {
            Text("Use global default").tag(EditorID?(nil))
            ForEach(EditorPickerRow.sorted(descriptors), id: \.id) { descriptor in
              EditorPickerRow.row(for: descriptor)
                .tag(EditorID?(descriptor.id))
            }
          }
        }

        Section("Worktree Base Directory") {
          LabeledContent("Path") {
            Text(project.worktreesDirectory ?? "—")
              .foregroundStyle(project.worktreesDirectory == nil ? .secondary : .primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          HStack {
            Button("Choose…") { chooseWorktreeDirectory() }
            if project.worktreesDirectory != nil {
              Button("Clear") {
                store.send(.setWorktreeBaseDirectory(nil))
              }
            }
            Spacer()
          }
        }
      }

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundColor(.red)
        }
      }
    }
    .formStyle(.grouped)
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
    let pane = NSOpenPanel()
    pane.canChooseDirectories = true
    pane.canChooseFiles = false
    pane.allowsMultipleSelection = false
    pane.message = "Choose a directory for worktree storage"
    pane.begin { response in
      if response == .OK, let url = pane.urls.first {
        store.send(.setWorktreeBaseDirectory(url.path))
      }
    }
  }
}
