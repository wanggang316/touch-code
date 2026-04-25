import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project General detail pane: per-Project editor override and worktree base
/// directory override. v3 moved both fields from `Project` in `catalog.json` to
/// `Settings.projects[pid]` in `settings.json`; reads go through
/// `@Environment(SettingsStore.self)` (observes the live store) and writes route
/// through `store.send(.setDefaultEditorOverride / .setWorktreeBaseDirectory)`
/// which internally calls `SettingsStore.mutateProject`. The catalog is still
/// consulted for identity (Project name / kind), never for the two preference
/// fields — post-drain those fields are always nil on the catalog side.
struct ProjectGeneralSettingsView: View {
  let projectID: ProjectID
  let store: StoreOf<ProjectSettingsFeature>
  let descriptors: [EditorDescriptor]

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    Form {
      if projectInCatalog() != nil {
        let entry = settingsStore.settings.projects[projectID]
        Section("Default Editor") {
          Picker(
            "Editor",
            selection: Binding<EditorID?>(
              get: { entry?.defaultEditor },
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
            Text(entry?.worktreesDirectory ?? "—")
              .foregroundStyle(entry?.worktreesDirectory == nil ? .secondary : .primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          HStack {
            Button("Choose…") { chooseWorktreeDirectory() }
            if entry?.worktreesDirectory != nil {
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

  /// Identity lookup only — used to confirm the Project still exists in the catalog
  /// before rendering. The two preference fields (`defaultEditor`, `worktreesDirectory`)
  /// live in `Settings.projects[pid]` in v3 and are NOT read from `project` here.
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
