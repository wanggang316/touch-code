import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Scaffold for the Project "Environment" sub-pane. Visible for both `git_repo` and
/// `plain_dir` Projects. The final surface will edit `ProjectSettings.envVars` — a
/// key/value editor whose contents are injected into every new pane opened under this
/// Project (prepended to the inherited environment). Signature frozen — see
/// ProjectGitSettingsView docstring.
struct ProjectEnvSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  var body: some View {
    ComingSoonPane(title: "Environment")
  }
}
