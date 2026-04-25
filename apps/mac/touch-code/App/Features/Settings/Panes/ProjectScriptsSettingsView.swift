import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Scaffold for the Project "Scripts" sub-pane. Visible for both `git_repo` and
/// `plain_dir` Projects. The final surface (M5) will edit
/// `ProjectSettings.scripts` and the worktree-lifecycle scripts on
/// `GitProjectSettings`.
struct ProjectScriptsSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  var body: some View {
    ComingSoonPane(title: "Scripts")
  }
}
