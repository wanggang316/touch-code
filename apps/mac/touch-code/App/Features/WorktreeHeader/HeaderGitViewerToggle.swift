import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Git Viewer overlay toggle. Reads `Worktree.gitViewerVisible` (via
/// `@Environment(HierarchyManager.self).catalog`) to drive the button's
/// appearance. The tap itself emits a delegate up to `RootFeature`, which
/// flips the persisted value through `.gitViewerToggledForCurrentWorktree`
/// — the same reducer branch ⌘⇧G uses. Keeping the write on one path
/// means the view-supplied `visible` flag can never drift from the value
/// the reducer reads from the live catalog snapshot.
struct HeaderGitViewerToggle: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let visible: Bool

  var body: some View {
    Button {
      store.send(.gitViewerToggleTapped)
    } label: {
      // Content-driven 1:1 square hit target — width grows with the
      // glyph metrics rather than being pinned to a fixed frame.
      Image(systemName: "doc.text.magnifyingglass")
        .foregroundStyle(visible ? Color.accentColor : .primary)
        .padding(4)
        .aspectRatio(1, contentMode: .fill)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(visible ? "Hide Git Viewer" : "Show Git Viewer")
    .help(visible ? "Hide Git Viewer" : "Show Git Viewer")
    .modifier(HeaderChipHover())
  }
}
