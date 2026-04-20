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
///   `ghosttyRuntime.surface(for:)`.
/// - Surfaces are destroyed explicitly via `HierarchyClient.closePanel`
///   → `HierarchyManager.closePanel` → `TerminalEngine.closeSurface`. The
///   view never disposes directly.
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
  let terminalEngine: TerminalEngine
  @Environment(HierarchyManager.self) private var hierarchyManager
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
    // Already registered? Reuse — the engine's registry is authoritative.
    if let existing = terminalEngine.ghosttyRuntime?.surface(for: panelID) {
      state = .ready(existing)
      return
    }
    guard let worktree = findWorktree(), let panel = findPanel(in: worktree) else {
      lazyLogger.warning("Panel \(panelID.description, privacy: .public) or its worktree disappeared before surface creation")
      state = .failed("Panel disappeared from catalog before its surface could be created.")
      return
    }
    do {
      let surface = try terminalEngine.ensureSurface(for: panel, in: worktree)
      state = .ready(surface)
    } catch {
      lazyLogger.error("ensureSurface failed for \(panelID.description, privacy: .public): \(String(describing: error), privacy: .public)")
      state = .failed(String(describing: error))
    }
  }

  private func findWorktree() -> Worktree? {
    hierarchyManager.catalog.spaces
      .first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  private func findPanel(in worktree: Worktree) -> Panel? {
    worktree.tabs
      .first(where: { $0.id == tabID })?
      .panels.first(where: { $0.id == panelID })
  }
}
