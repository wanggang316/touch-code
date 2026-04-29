import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Top Header row above the terminal Tab bar. Left: read-only branch label.
/// Right cluster: Open-in split button, Git Viewer toggle.
struct WorktreeHeaderView: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let editorStore: StoreOf<EditorFeature>
  let projectID: ProjectID
  let worktreePath: String
  let branchLabel: String
  let gitViewerVisible: Bool
  /// Gates the branch label and the Git Viewer toggle for non-git Projects
  /// (P-Q4 = a). Defaults to `true` so existing call sites that haven't
  /// threaded the predicate still render the git chrome — new call sites on
  /// `feat/project-mgmt` pass the real value from the owning Project.
  var supportsWorktrees: Bool = true

  var body: some View {
    HStack(spacing: 10) {
      if supportsWorktrees {
        Label(branchLabel, systemImage: "point.3.connected.trianglepath.dotted")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityLabel("Current branch: \(branchLabel)")
          .accessibilityAddTraits(.isStaticText)
      }

      HStack(spacing: 6) {
        HeaderOpenSplitButton(
          store: store,
          editorStore: editorStore,
          projectID: projectID,
          worktreePath: worktreePath
        )
        if supportsWorktrees {
          HeaderGitViewerToggle(
            store: store,
            visible: gitViewerVisible
          )
        }
      }
    }
  }
}
