import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Repository Hooks detail pane (spec M12): read-only merged list of hooks that fire
/// against the current Project. Each row is tagged Global or Repository depending on
/// whether its scope binds it to one of the project's worktrees. Signature and `projectID`
/// parameter are frozen contracts.
struct RepositoryHooksSettingsView: View {
  @Environment(StoreOf<RepositorySettingsFeature>.self) var repositoryStore

  let projectID: ProjectID

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        switch repositoryStore.hooksLoad {
        case .idle:
          Text("Loading hooks...")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
              repositoryStore.send(.onHooksAppear)
            }

        case .loading:
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let rows):
          HookMergeView(
            rows: rows,
            emptyStateTitle: "No hooks configured for this project.",
            showsSourceTag: true,
            trailingAction: TrailingAction(
              title: "Reveal hooks.json in Finder",
              systemImage: "folder"
            ) {
              repositoryStore.send(.revealHooksJSONRequested)
            }
          )

        case .failed(let error):
          VStack(alignment: .leading, spacing: 8) {
            Label("Failed to load hooks", systemImage: "exclamationmark.circle.fill")
              .foregroundColor(.red)
            Text(error)
              .font(.caption)
              .foregroundColor(.secondary)
            Button("Retry") {
              repositoryStore.send(.onHooksAppear)
            }
            .buttonStyle(.bordered)
          }
          .padding(8)
          .background(Color(nsColor: .systemRed).opacity(0.1), in: .rect(cornerRadius: 6))
        }

        Spacer()
      }
      .padding(16)
    }
  }
}

#Preview {
  RepositoryHooksSettingsView(projectID: ProjectID())
    .frame(width: 500, height: 300)
}
