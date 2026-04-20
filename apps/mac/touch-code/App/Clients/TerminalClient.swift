import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency-injection bridge over `TerminalEngine`. Features depend on
/// this struct's closures, not on the engine directly; the `liveValue` binds
/// each closure to a concrete `TerminalEngine` instance at app startup via
/// `.withDependencies`.
nonisolated struct TerminalClient: Sendable {
  var sendInput: @MainActor @Sendable (_ panelID: PanelID, _ text: String) -> Void
  var setFocus: @MainActor @Sendable (_ panelID: PanelID, _ focused: Bool) -> Void
  var retryPanel: @MainActor @Sendable (_ panelID: PanelID) -> Bool

  /// Create or return the existing `PanelSurface` for the panel. Throws
  /// `TerminalClient.Error.worktreeNotFound` if the worktree address doesn't
  /// resolve inside the current catalog. The client takes the full address
  /// so the engine's `ensureSurface(for:in:)` can hand the `Worktree`
  /// struct to ghostty as the surface config's working directory source.
  var ensureSurface: @MainActor @Sendable (
    _ panelID: PanelID, _ inTab: TabID, _ inWorktree: WorktreeID,
    _ inProject: ProjectID, _ inSpace: SpaceID
  ) throws -> Void
  var closeSurface: @MainActor @Sendable (_ panelID: PanelID) -> Void

  /// Look up an existing `PanelSurface` registered with the engine. Returns
  /// `nil` when no surface has been created for the panel yet; callers
  /// (notably `LazyPanelHost`) should call `ensureSurface` first on a
  /// cache miss.
  var surface: @MainActor @Sendable (_ panelID: PanelID) -> PanelSurface?

  /// Event stream from the engine. Multi-consumer: each call returns a fresh
  /// subscriber registration. Lifecycle events always delivered; output
  /// events drop under per-subscriber backpressure (shipped M4.5 semantic).
  var events: @MainActor @Sendable () -> AsyncStream<TerminalEvent>

  enum Error: Swift.Error, Equatable, Sendable {
    case worktreeNotFound(WorktreeID)
    case panelNotFound(PanelID)
  }
}

// MARK: - Live bridge

extension TerminalClient {
  @MainActor
  static func live(engine: TerminalEngine) -> TerminalClient {
    TerminalClient(
      sendInput: { panelID, text in
        engine.ghosttyRuntime?.surface(for: panelID)?.sendInput(text)
      },
      setFocus: { panelID, focused in
        engine.ghosttyRuntime?.surface(for: panelID)?.setFocus(focused)
      },
      retryPanel: { panelID in engine.retryPanel(panelID) },
      ensureSurface: { panelID, tabID, worktreeID, projectID, spaceID in
        let catalog = engine.hierarchy.catalog
        guard
          let space = catalog.spaces.first(where: { $0.id == spaceID }),
          let project = space.projects.first(where: { $0.id == projectID }),
          let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
          let tab = worktree.tabs.first(where: { $0.id == tabID }),
          let panel = tab.panels.first(where: { $0.id == panelID })
        else {
          throw TerminalClient.Error.worktreeNotFound(worktreeID)
        }
        _ = try engine.ensureSurface(for: panel, in: worktree)
      },
      closeSurface: { panelID in engine.closeSurface(for: panelID) },
      surface: { panelID in engine.ghosttyRuntime?.surface(for: panelID) },
      events: { engine.events() }
    )
  }
}

// MARK: - DependencyKey

extension TerminalClient: DependencyKey {
  static let liveValue: TerminalClient = TerminalClient(
    sendInput: { _, _ in fatalError("TerminalClient.liveValue not configured; wire via .withDependencies at app startup") },
    setFocus: { _, _ in fatalError("TerminalClient.liveValue not configured") },
    retryPanel: { _ in fatalError("TerminalClient.liveValue not configured") },
    ensureSurface: { _, _, _, _, _ in fatalError("TerminalClient.liveValue not configured") },
    closeSurface: { _ in fatalError("TerminalClient.liveValue not configured") },
    surface: { _ in nil },
    events: { AsyncStream { $0.finish() } }
  )

  static let testValue: TerminalClient = TerminalClient(
    sendInput: unimplemented("TerminalClient.sendInput"),
    setFocus: unimplemented("TerminalClient.setFocus"),
    retryPanel: unimplemented("TerminalClient.retryPanel", placeholder: false),
    ensureSurface: unimplemented("TerminalClient.ensureSurface"),
    closeSurface: unimplemented("TerminalClient.closeSurface"),
    surface: unimplemented("TerminalClient.surface", placeholder: nil),
    events: unimplemented(
      "TerminalClient.events",
      placeholder: AsyncStream { $0.finish() }
    )
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
