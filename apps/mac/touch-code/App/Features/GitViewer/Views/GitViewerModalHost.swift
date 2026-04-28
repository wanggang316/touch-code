import ComposableArchitecture
import SwiftUI

/// Centered modal host for `GitViewerView`. Mounted by `WorktreeDetailView` when
/// the active Worktree's `gitViewerVisible` is `true`. The modal overlays the
/// detail column only — the Sidebar stays interactive — and the translucent scrim
/// around the card dispatches `onDismiss` on tap, mirroring `CommandPaletteView`'s
/// dismissal composition.
///
/// Sizing is responsive inside explicit bounds via `cardSize(in:)`. Both axes apply
/// a fixed gutter, then clamp to a min and a max so the card neither shrinks below
/// readability nor stretches past usable diff width on large displays.
///
/// Dismissal funnels — scrim tap, Esc, and (driven by the parent) ⌘⇧G — all invoke
/// `onDismiss`; the parent converts that into the existing
/// `gitViewerToggleRequested` action so the Header GV button's highlight state
/// stays in sync with the modal's mount state by construction.
struct GitViewerModalHost: View {
  let store: StoreOf<GitViewerFeature>
  let onDismiss: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let card = Self.cardSize(in: proxy.size)
      ZStack {
        Color.black.opacity(0.12)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { onDismiss() }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Dismiss Git Viewer")

        GitViewerView(store: store)
          .frame(width: card.width, height: card.height)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .shadow(radius: 24, y: 10)
          .onKeyPress(.escape) {
            onDismiss()
            return .handled
          }
          .accessibilityElement(children: .contain)
      }
    }
  }

  /// Pure layout helper: per-axis (gutter, min, max) clamp of the container size.
  /// Width: gutter 48, min 560, max 980. Height: gutter 56, min 420, max 760.
  /// Kept static + free of SwiftUI types so `GitViewerModalHostSizingTests` can
  /// drive the three regimes (below-min / in-range / above-max) per axis without
  /// any layout plumbing.
  static func cardSize(in containerSize: CGSize) -> CGSize {
    let w = max(minWidth, min(maxWidth, containerSize.width - 2 * widthGutter))
    let h = max(minHeight, min(maxHeight, containerSize.height - 2 * heightGutter))
    return CGSize(width: w, height: h)
  }

  private static let widthGutter: CGFloat = 48
  private static let minWidth: CGFloat = 560
  private static let maxWidth: CGFloat = 980
  private static let heightGutter: CGFloat = 56
  private static let minHeight: CGFloat = 420
  private static let maxHeight: CGFloat = 760
}
