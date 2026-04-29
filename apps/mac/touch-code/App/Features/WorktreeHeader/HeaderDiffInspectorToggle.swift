import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Git Viewer overlay toggle. Reads `Worktree.diffInspectorVisible` (via
/// `@Environment(HierarchyManager.self).catalog`) to drive the button's
/// appearance. The tap itself emits a delegate up to `RootFeature`, which
/// flips the persisted value through `.diffInspectorToggledForCurrentWorktree`
/// — the same reducer branch ⌘⇧G uses. Keeping the write on one path
/// means the view-supplied `visible` flag can never drift from the value
/// the reducer reads from the live catalog snapshot.
struct HeaderDiffInspectorToggle: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let visible: Bool

  var body: some View {
    Button {
      store.send(.diffInspectorToggleTapped)
    } label: {
      Image(systemName: "doc.text.magnifyingglass")
        .foregroundStyle(visible ? Color.accentColor : .primary)
        .commandKeyHint(.toggleDiffInspector)
    }
    .accessibilityLabel(visible ? "Hide Git Viewer" : "Show Git Viewer")
    .help(visible ? "Hide Git Viewer" : "Show Git Viewer")
  }
}
