import Foundation
import TouchCodeCore

/// Public-facing façade that composes `CatalogStore`, `HierarchyManager`, and
/// `GhosttyRuntime` behind a single event stream. Feature code (TCA clients,
/// hook runner, notifications) subscribes via `events()` and mutates state
/// through `hierarchy`. Direct access to `GhosttyRuntime` or `PanelSurface`
/// objects is intentionally not exposed.
@MainActor
final class TerminalEngine {
  /// Crash isolation policy: N crashes within the window auto-closes the
  /// enclosing Tab. Mirrors supaterm's controller behaviour.
  struct CrashPolicy: Equatable, Sendable {
    var maxCrashesInWindow: Int = 3
    var window: TimeInterval = 30
    static let `default` = CrashPolicy()
  }

  let hierarchy: HierarchyManager
  let store: CatalogStore
  var crashPolicy: CrashPolicy = .default

  private let eventStream: AsyncStream<TerminalEvent>
  private let eventContinuation: AsyncStream<TerminalEvent>.Continuation
  private var outputBuffers: [PanelID: PendingOutputBuffer] = [:]
  private var crashRings: [PanelID: [Date]] = [:]
  private let clock: @Sendable () -> Date

  init(
    store: CatalogStore,
    hierarchy: HierarchyManager,
    clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.hierarchy = hierarchy
    self.clock = clock
    // Cap the buffer so a stalled consumer can't grow memory without bound —
    // one slow subscriber with N panels can otherwise retain every batch.
    let (stream, continuation) = AsyncStream<TerminalEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    self.eventStream = stream
    self.eventContinuation = continuation
  }

  /// Returns the shared event stream. Multiple subscribers are not supported —
  /// wrap with an `AsyncChannel` or multicaster if you need fan-out.
  func events() -> AsyncStream<TerminalEvent> {
    eventStream
  }

  /// Emit an event on the shared stream. Intended for `HierarchyRuntime`
  /// adapters to signal structural transitions (`panelReady`, `panelExited`)
  /// and for hierarchy mutations to announce `tabActivated` / `worktreeActivated`.
  func emit(_ event: TerminalEvent) {
    eventContinuation.yield(event)
  }

  /// Feed bytes from a ghostty surface into the per-panel coalescer. Creates
  /// a buffer on first use. Callers should invoke `flushOutput(for:)` before
  /// tearing the surface down so no bytes are dropped.
  func appendOutput(panelID: PanelID, bytes: Data) {
    let buffer = outputBuffers[panelID] ?? makeBuffer(for: panelID)
    buffer.append(bytes)
  }

  func flushOutput(for panelID: PanelID) {
    outputBuffers[panelID]?.flush()
  }

  /// Drop the per-panel output buffer. Must be called when the surface closes,
  /// otherwise pending bytes leak and the coalescer continues emitting.
  func disposeOutputBuffer(for panelID: PanelID) {
    outputBuffers[panelID]?.flush()
    outputBuffers.removeValue(forKey: panelID)
  }

  func finishEventStream() {
    eventContinuation.finish()
  }

  // MARK: - Crash isolation

  /// Records a panel crash, emits `.panelCrashed`, and if the panel exceeds
  /// `crashPolicy.maxCrashesInWindow` crashes within `crashPolicy.window`,
  /// closes the enclosing Tab and emits `.tabAutoClosed`.
  ///
  /// Returns true when the panel survived (under the threshold), false when
  /// the enclosing tab was auto-closed. Callers can use the return value to
  /// decide whether to render a "retry" placeholder or a toast.
  @discardableResult
  func recordPanelCrash(
    panelID: PanelID,
    reason: String
  ) -> Bool {
    emit(.panelCrashed(panelID, reason: reason))
    disposeOutputBuffer(for: panelID)

    let now = clock()
    let cutoff = now.addingTimeInterval(-crashPolicy.window)
    var ring = crashRings[panelID, default: []].filter { $0 >= cutoff }
    ring.append(now)
    crashRings[panelID] = ring

    guard ring.count >= crashPolicy.maxCrashesInWindow else {
      return true
    }

    guard let location = findPanel(panelID) else {
      crashRings.removeValue(forKey: panelID)
      return false
    }

    do {
      try hierarchy.closeTab(
        location.tabID,
        in: location.worktreeID,
        in: location.projectID,
        in: location.spaceID
      )
    } catch {
      return false
    }

    crashRings.removeValue(forKey: panelID)
    emit(.tabAutoClosed(
      location.tabID,
      reason: "Panel crashed \(ring.count) times within \(Int(crashPolicy.window))s"
    ))
    return false
  }

  /// Retry a crashed panel. M5 replaces the stub body with real surface
  /// recreation; today it clears the crash ring and emits a synthetic
  /// `.panelReady` so TCA feature code can be wired end-to-end.
  func retryPanel(_ panelID: PanelID) {
    crashRings.removeValue(forKey: panelID)
    emit(.panelReady(panelID))
  }

  // MARK: - Private

  private struct PanelLocation {
    let spaceID: SpaceID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let tabID: TabID
  }

  private func findPanel(_ panelID: PanelID) -> PanelLocation? {
    for space in hierarchy.catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs where tab.panels.contains(where: { $0.id == panelID }) {
            return PanelLocation(
              spaceID: space.id,
              projectID: project.id,
              worktreeID: worktree.id,
              tabID: tab.id
            )
          }
        }
      }
    }
    return nil
  }

  private func makeBuffer(for panelID: PanelID) -> PendingOutputBuffer {
    let buffer = PendingOutputBuffer(panelID: panelID) { [weak self] id, data in
      self?.emit(.panelOutput(id, data))
    }
    outputBuffers[panelID] = buffer
    return buffer
  }
}
