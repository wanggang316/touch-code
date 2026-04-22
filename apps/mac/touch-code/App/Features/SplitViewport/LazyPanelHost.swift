import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Pure renderer for a single panel slot. Drives `PanelHostFeature` via
/// `.task { store.send(.task) }` and switches over `store.phase` to show
/// a loading placeholder, the live `PanelHostView`, or a failure with
/// retry. All `TerminalClient` calls live in the reducer — this view never
/// reads `@Dependency` directly, which was the source of the
/// `TerminalClient.liveValue not configured` fatal-error on launch with
/// a persisted catalog (reducer-scope overrides don't reach SwiftUI view
/// bodies).
///
/// Surfaces are retained across tab switches by `TerminalEngine`'s
/// registry. The reducer's registry short-circuit reuses them on
/// reappearance; explicit teardown still goes through
/// `HierarchyClient.closePanel` → `TerminalEngine.closeSurface`.
struct LazyPanelHost: View {
  @Bindable var store: StoreOf<PanelHostFeature>

  var body: some View {
    content
      .task(id: store.panelID) {
        store.send(.task)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .ready:
      if let surface = store.surface?.surface {
        PanelHostView(surface: surface)
          .background(Color.black)
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
    VStack(spacing: 6) {
      ProgressView()
      Text("Creating surface…")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private func failurePlaceholder(message: String) -> some View {
    VStack(spacing: 8) {
      Text("Panel failed to start")
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
