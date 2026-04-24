import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root SwiftUI view for the Worktree Status Bar's center slot. Picks one
/// of five forms by priority; currently only the toast form is implemented
/// (M1 skeleton). PR, motivational, and narrow-width fallbacks land in
/// subsequent milestones (M4, M5, M6).
///
/// The view is mounted via `ToolbarItem(placement: .principal)` in
/// `WorktreeDetailView`. `ToolbarSpacer(.flexible)` on either side keeps
/// the slot centered regardless of the left / right toolbar group widths.
struct StatusBarView: View {
  @Bindable var store: StoreOf<StatusBarFeature>

  var body: some View {
    Group {
      if let toast = store.toast {
        StatusToastView(toast: toast)
          .transition(.opacity)
      } else {
        // M1 skeleton: no PR / motivational form yet. Rendering a 1pt
        // clear box keeps the ToolbarItem non-empty so SwiftUI stays
        // consistent across state transitions — collapses to invisible
        // without breaking the left / right spacer layout.
        Color.clear.frame(width: 1, height: 1)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: store.toast)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("status.bar")
  }
}
