import SwiftUI
import TouchCodeCore

/// Placeholder for the Repository General detail pane (per-Project default editor + worktree
/// base directory). T4 replaces this body with the real UI (spec M11), reading/writing
/// `Project.defaultEditor` and `Project.worktreesDirectory` through `HierarchyClient` per
/// design D1. Signature and `projectID` parameter are frozen so the detail switch in
/// `SettingsWindowView` does not churn across waves.
struct RepositoryGeneralSettingsView: View {
  let projectID: ProjectID

  var body: some View {
    Text("TODO: supplied by T4 for \(projectID.raw.uuidString)")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  RepositoryGeneralSettingsView(projectID: ProjectID())
    .frame(width: 500, height: 300)
}
