import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Scaffold for the Project "Scripts" sub-pane. Visible for both `git_repo` and
/// `plain_dir` Projects. The final surface will edit `ProjectSettings.scripts` — a list
/// of `ScriptDefinition` entries with kind / icon / colour / command that feed the
/// command palette + tab-bar quick-launch affordances. Signature frozen — see
/// ProjectGitSettingsView docstring.
struct ProjectScriptsSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  var body: some View {
    ComingSoonPane(title: "Scripts")
  }
}
