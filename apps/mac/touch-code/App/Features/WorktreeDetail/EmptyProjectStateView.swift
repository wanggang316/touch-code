import SwiftUI

/// Detail-pane placeholder shown when no Worktree is selected — typically
/// on first launch before any Project has been added, or after the catalog
/// pruned every existing Project. Mirrors supacode's `EmptyStateView`:
/// muted icon, title, hint, and a primary action that drops the user
/// straight into the Add Project picker without forcing them to hunt
/// for the sidebar toolbar button.
struct EmptyProjectStateView: View {
  let onAddProject: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "tray")
        .font(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text("Open a Project")
          .font(.title3)
        Text("Add a Project or Folder from the sidebar to start working on a Worktree.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Button("Add Project…") { onAddProject() }
        .controlSize(.regular)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

#Preview {
  EmptyProjectStateView(onAddProject: {})
    .frame(width: 600, height: 400)
}
