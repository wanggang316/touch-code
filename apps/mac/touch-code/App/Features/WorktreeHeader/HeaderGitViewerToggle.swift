import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Git Viewer overlay toggle. Same explicit-geometry chip contract as
/// the sibling split buttons (see `HeaderOpenSplitButton`), but with a
/// single 1:1 inner button rather than two halves.
struct HeaderGitViewerToggle: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let visible: Bool

  static let innerHeight: CGFloat = HeaderOpenSplitButton.innerHeight
  static let gap: CGFloat = HeaderOpenSplitButton.gap

  var body: some View {
    Button {
      store.send(.gitViewerToggleTapped)
    } label: {
      Image(systemName: "doc.text.magnifyingglass")
        .foregroundStyle(visible ? Color.accentColor : .primary)
        .frame(width: Self.innerHeight, height: Self.innerHeight)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(visible ? "Hide Git Viewer" : "Show Git Viewer")
    .help(visible ? "Hide Git Viewer" : "Show Git Viewer")
    .modifier(HeaderChipHover())
    .padding(Self.gap)
    .background(
      Capsule(style: .continuous)
        .fill(.regularMaterial)
    )
  }
}
