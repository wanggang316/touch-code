import ComposableArchitecture
import OSLog
import SwiftUI
import TouchCodeCore

private let lazyLogger = Logger(subsystem: "com.touch-code.shell", category: "lazy-panel")

/// View wrapper that lazily creates a `PanelSurface` on first appearance
/// and then hosts it via `PanelHostView`. Implements the M5 lifecycle:
///
/// - Surface is created when the view appears (one-frame slot after tab
///   activation), not when the tab or panel is added to the catalog.
/// - Surfaces are retained across tab switches: the view disappearing when
///   a tab becomes inactive does NOT destroy the surface. The engine
///   keeps it in its registry; reappearing looks it up again via
///   `terminalClient.surface(for:)`.
/// - Surfaces are destroyed explicitly via `HierarchyClient.closePanel`
///   → `HierarchyManager.closePanel` → `TerminalEngine.closeSurface`. The
///   view never disposes directly.
///
/// Routed through `TerminalClient` (not `TerminalEngine` directly) so
/// tests can override behaviour with `@Dependency` instead of requiring a
/// full engine stack.
///
/// If `ensureSurface` throws (e.g. engine has no `GhosttyRuntime` or the
/// panel address no longer resolves), the view shows an error placeholder
/// with a "Retry" button that re-runs the lookup.
struct LazyPanelHost: View {
  let panelID: PanelID
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  @Dependency(TerminalClient.self) private var terminalClient
  @State private var state: LoadState = .loading

  enum LoadState {
    case loading
    case ready(PanelSurface)
    case failed(String)
  }

  var body: some View {
    content
      .task(id: panelID) {
        ensureSurface()
      }
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .ready(let surface):
      PanelHostView(surface: surface)
        .background(Color.black)
    case .loading:
      VStack(spacing: 6) {
        ProgressView()
        Text("Creating surface…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .underPageBackgroundColor))
    case .failed(let message):
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
          state = .loading
          ensureSurface()
        }
        .buttonStyle(.bordered)
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .underPageBackgroundColor))
    }
  }

  private func ensureSurface() {
    // Registry short-circuit: if the engine already has the surface, reuse
    // it without re-invoking ensureSurface (harmlessly idempotent, but
    // saves the catalog walk + keeps logs quieter).
    if let existing = terminalClient.surface(panelID) {
      state = .ready(existing)
      return
    }
    do {
      try terminalClient.ensureSurface(panelID, tabID, worktreeID, projectID, spaceID)
    } catch {
      lazyLogger.error("ensureSurface failed for \(panelID.description, privacy: .public): \(String(describing: error), privacy: .public)")
      state = .failed(String(describing: error))
      return
    }
    // ensureSurface succeeded; look up the just-registered surface.
    if let surface = terminalClient.surface(panelID) {
      state = .ready(surface)
    } else {
      // Shouldn't happen unless ensureSurface silently no-opped (e.g.
      // runtime unavailable was swallowed). Surface a diagnostic.
      lazyLogger.warning("ensureSurface returned success but surface(for:) resolved nil for \(panelID.description, privacy: .public)")
      state = .failed("Surface not registered after creation.")
    }
  }
}
