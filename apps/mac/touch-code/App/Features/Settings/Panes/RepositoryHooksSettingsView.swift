import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Repository Hooks detail pane (spec M12): read-only merged list of hooks that fire
/// against the current Project. Each row is tagged Global or Repository depending on
/// whether its scope binds it to one of the project's worktrees (or its repo root).
/// `store` is scoped by `SettingsWindowView` before construction and keyed by
/// `projectID`.
struct RepositoryHooksSettingsView: View {
  let projectID: ProjectID
  let store: StoreOf<ProjectSettingsFeature>

  var body: some View {
    Form {
      Section {
        switch store.state.hooksLoad {
        case .idle:
          Color.clear
            .frame(height: 1)
            .onAppear { store.send(.onHooksAppear) }

        case .loading:
          ProgressView()
            .frame(maxWidth: .infinity)

        case .loaded(let rows):
          HookMergeView(
            rows: rows,
            emptyStateTitle: "No hooks configured for this project.",
            showsSourceTag: true,
            trailingAction: TrailingAction(
              title: "Reveal hooks.json in Finder",
              systemImage: "folder"
            ) {
              store.send(.revealHooksJSONRequested)
            }
          )

        case .failed(let error):
          VStack(alignment: .leading, spacing: 8) {
            Label("Failed to load hooks", systemImage: "exclamationmark.circle.fill")
              .foregroundColor(.red)
            Text(error)
              .font(.caption)
              .foregroundColor(.secondary)
            Button("Retry") { store.send(.onHooksAppear) }
              .buttonStyle(.bordered)
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}
