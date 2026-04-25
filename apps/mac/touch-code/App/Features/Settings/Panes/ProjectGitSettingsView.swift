import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Scaffold for the Project "Git & Worktree" sub-pane. Renders only when the selected
/// Project is `git_repo`; hidden from the sidebar entirely for `plain_dir`. The final
/// surface will edit `ProjectSettings.git.{worktreeBaseRef, copyIgnored*,
/// copyUntracked*, worktreesDirectory}` with inline "Use global default" caption lines.
/// Signature frozen: the view carries `projectID` + a scoped `ProjectSettingsFeature`
/// store so follow-up implementation can wire action dispatch without touching the
/// SettingsWindowView detail switch.
struct ProjectGitSettingsView: View {
  let projectID: ProjectID
  @Bindable var store: StoreOf<ProjectSettingsFeature>

  var body: some View {
    ComingSoonPane(title: "Git & Worktree")
  }
}
