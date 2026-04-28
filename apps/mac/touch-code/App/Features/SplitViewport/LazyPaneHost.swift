import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Pure renderer for a single pane slot. Drives `PaneHostFeature` via
/// `.task { store.send(.task) }` and switches over `store.phase` to show
/// a loading placeholder, the live `PaneHostView`, or a failure with
/// retry. All `TerminalClient` calls live in the reducer — this view never
/// reads `@Dependency` directly, which was the source of the
/// `TerminalClient.liveValue not configured` fatal-error on launch with
/// a persisted catalog (reducer-scope overrides don't reach SwiftUI view
/// bodies).
///
/// Surfaces are retained across tab switches by `TerminalEngine`'s
/// registry. The reducer's registry short-circuit reuses them on
/// reappearance; explicit teardown still goes through
/// `HierarchyClient.closePane` → `TerminalEngine.closeSurface`.
struct LazyPaneHost: View {
  @Bindable var store: StoreOf<PaneHostFeature>

  var body: some View {
    content
      .task(id: store.paneID) {
        store.send(.task)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .ready:
      if let surface = store.surface?.surface {
        // No `.background(Color.black)` here. ghostty's Metal layer paints the
        // entire pane — an extra black SwiftUI background is both redundant
        // (hidden the moment ghostty renders) and actively harmful: it bleeds
        // into the sidebar material above via NavigationSplitView's z-stack
        // (sidebar material blends `withinWindow`, i.e. against detail pixels
        // underneath), producing a visible black band behind the sidebar's
        // translucent layer in light mode.
        PaneHostView(surface: surface)
          // 2pt progress strip pinned to the top edge of the surface,
          // driven by libghostty's OSC 9;4 reports (winget, gh,
          // Claude Code, etc.). `surface.info` is `@Observable`, so the
          // overlay appears/disappears purely from the read site here.
          .overlay(alignment: .top) {
            PaneSurfaceProgressOverlay(surface: surface)
          }
          .animation(
            .easeInOut(duration: 0.2),
            value: surface.info.progressState
          )
      } else {
        // Should not happen — `phase == .ready` is set by the reducer
        // only together with a non-nil `surface`. Render the loading
        // placeholder as a defensive no-op so an unexpected state doesn't
        // show a broken surface.
        loadingPlaceholder
      }
    case .loading:
      loadingPlaceholder
    case .failed(let message):
      failurePlaceholder(message: message)
    }
  }

  private var loadingPlaceholder: some View {
    // Spinner + a shimmering caption match supacode's launch beat for
    // panes that are still negotiating with the engine. Background is
    // `underPageBackgroundColor` so the pane reads as "not yet a
    // terminal" instead of fighting Ghostty's eventual black canvas.
    VStack(spacing: 8) {
      Image(systemName: "apple.terminal.on.rectangle")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      ProgressView()
        .controlSize(.small)
      Text("Spinning up shell…")
        .font(.caption)
        .foregroundStyle(.secondary)
        .shimmer(isActive: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private func failurePlaceholder(message: String) -> some View {
    VStack(spacing: 8) {
      Text("Pane failed to start")
        .font(.headline)
        .foregroundStyle(.red)
      Text(message)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
      Button("Retry") {
        store.send(.retryButtonTapped)
      }
      .buttonStyle(.bordered)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}
