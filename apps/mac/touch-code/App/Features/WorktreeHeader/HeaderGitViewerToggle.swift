import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Git Viewer overlay toggle. Reads `Worktree.gitViewerVisible` (via
/// `@Environment(HierarchyManager.self).catalog`) and dispatches a flip
/// through `WorktreeHeaderFeature` so the mutation lands on
/// `HierarchyClient.setWorktreeGitViewerVisible`. T2 only swings the
/// flag; T3 wires the actual overlay presentation to the same flag.
struct HeaderGitViewerToggle: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let worktreeID: WorktreeID
  let visible: Bool

  var body: some View {
    Button {
      store.send(.gitViewerToggled(
        worktreeID: worktreeID,
        currentVisibility: visible
      ))
    } label: {
      Image(systemName: "doc.text.magnifyingglass")
        .foregroundStyle(visible ? Color.accentColor : .primary)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(visible ? "Hide Git Viewer" : "Show Git Viewer")
    .help(visible ? "Hide Git Viewer" : "Show Git Viewer")
  }
}
