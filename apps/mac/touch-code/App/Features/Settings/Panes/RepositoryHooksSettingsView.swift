import SwiftUI
import TouchCodeCore

/// Placeholder for the Repository Hooks detail pane (merged view of global + per-Repo hooks).
/// T4 replaces this body with the real UI (spec M12). Signature and `projectID` parameter are
/// frozen so the detail switch in `SettingsWindowView` does not churn across waves.
struct RepositoryHooksSettingsView: View {
  let projectID: ProjectID

  var body: some View {
    Text("TODO: supplied by T4 for \(projectID.raw.uuidString)")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  RepositoryHooksSettingsView(projectID: ProjectID())
    .frame(width: 500, height: 300)
}
