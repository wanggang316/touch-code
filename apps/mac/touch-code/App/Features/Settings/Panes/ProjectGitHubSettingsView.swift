import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Scaffold for the Project "GitHub" sub-pane. Renders only when the selected Project
/// is `git_repo`; hidden for `plain_dir`. The final surface will edit
/// `ProjectSettings.git.{defaultMergeStrategy, postMergeAction, githubDisabled}` with
/// inline "Use global default" caption lines. Signature frozen — see
/// ProjectGitSettingsView docstring.
struct ProjectGitHubSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  var body: some View {
    ComingSoonPane(title: "GitHub")
  }
}
