import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Top Header row above the terminal Tab bar. Left: read-only branch label.
/// Right cluster (in order): notification bell, Open-in split button,
/// Git Viewer toggle. Replaces the ad-hoc `worktreeHeader(address:)` strip
/// previously inlined in `WorktreeDetailView`.
struct WorktreeHeaderView: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let editorStore: StoreOf<EditorFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreePath: String
  let branchLabel: String
  let gitViewerVisible: Bool

  var body: some View {
    HStack(spacing: 10) {
      Label(branchLabel, systemImage: "point.3.connected.trianglepath.dotted")
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityLabel("Current branch: \(branchLabel)")
        .accessibilityAddTraits(.isStaticText)

      Spacer(minLength: 8)

      HStack(spacing: 6) {
        HeaderBellView(store: store)
        HeaderOpenSplitButton(
          store: store,
          editorStore: editorStore,
          spaceID: spaceID,
          projectID: projectID,
          worktreePath: worktreePath
        )
        HeaderGitViewerToggle(
          store: store,
          visible: gitViewerVisible
        )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
