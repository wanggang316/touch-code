import Foundation
import TouchCodeCore

/// Public-facing façade that composes `CatalogStore`, `HierarchyManager`, and
/// `GhosttyRuntime` behind a fan-out event stream. Feature code (TCA clients,
/// hook runner, notifications) subscribes via `events()` and mutates state
/// through `hierarchy`. Direct access to `GhosttyRuntime` or `PanelSurface`
/// objects is intentionally not exposed.
///
/// Lifecycle events (`panelCreated`, `panelReady`, `panelExited`,
/// `panelCrashed`, `tabActivated`, `tabAutoClosed`, `worktreeActivated`,
/// `hierarchyMutated`) are delivered with a large per-subscriber buffer
/// because drops cause persistence and UI desync that can't be recovered.
/// Output events (`panelOutput`, `panelIdle`) are delivered with a small
/// `.bufferingNewest` policy — scrollback retains history, so dropping
/// coalesced batches under consumer backpressure is safe.
@MainActor
final class TerminalEngine {
  struct CrashPolicy: Equatable, Sendable {
    var maxCrashesInWindow: Int = 3
    var window: TimeInterval = 30
    static let `default` = CrashPolicy()
  }

  /// Per-subscriber event fan-out. Each `events()` call registers a fresh
  /// continuation. The engine broadcasts every emit to every active
  /// subscriber until they cancel or finish.
  private final class SubscriberRegistry {
    struct Subscriber: Identifiable {
      let id: UUID
      let continuation: AsyncStream<TerminalEvent>.Continuation
      let lifecycleOnly: Bool
    }

    var subscribers: [Subscriber] = []

    func broadcast(_ event: TerminalEvent) {
      let isLifecycle = event.isLifecycle
      for subscriber in subscribers where isLifecycle || !subscriber.lifecycleOnly {
        subscriber.continuation.yield(event)
      }
    }

    func finishAll() {
      for subscriber in subscribers {
        subscriber.continuation.finish()
      }
      subscribers.removeAll()
    }
  }

  let hierarchy: HierarchyManager
  let store: CatalogStore
  let ghosttyRuntime: GhosttyRuntime?
  var crashPolicy: CrashPolicy = .default

  private let registry = SubscriberRegistry()
  private var outputBuffers: [PanelID: PendingOutputBuffer] = [:]
  private var crashRings: [PanelID: [Date]] = [:]
  private let clock: @Sendable () -> Date
  private var finished = false

  /// Inject a `GhosttyRuntime` for real panel surfaces, or pass `nil` for
  /// headless tests. When nil, `ensureSurface` throws.
  init(
    store: CatalogStore,
    hierarchy: HierarchyManager,
    ghosttyRuntime: GhosttyRuntime? = nil,
    clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.hierarchy = hierarchy
    self.ghosttyRuntime = ghosttyRuntime
    self.clock = clock
  }

  // MARK: - Panel surface lifecycle

  enum SurfaceError: Error, Sendable {
    case runtimeUnavailable
    case panelHasNoTab
  }

  /// Create a libghostty surface for the given Panel. Idempotent: if a
  /// surface is already registered for the panel, returns the existing one.
  /// Wires the surface's `onClose` to emit the lifecycle event + dispose
  /// buffer. Throws `panelHasNoTab` if the Panel isn't yet wired into a
  /// Tab — the engine uses the Tab ID in the `.panelCreated` event, so
  /// callers must add the Panel to a Tab via `HierarchyManager.openPanel`
  /// (or `splitPanel`) before calling this.
  @discardableResult
  func ensureSurface(for panel: Panel, in worktree: Worktree) throws -> PanelSurface {
    guard let runtime = ghosttyRuntime else { throw SurfaceError.runtimeUnavailable }
    if let existing = runtime.surface(for: panel.id) {
      return existing
    }
    guard let tabID = tabIDForPanel(panel.id) else {
      throw SurfaceError.panelHasNoTab
    }
    let surface = try PanelSurface(
      runtime: runtime,
      panelID: panel.id,
      workingDirectory: panel.workingDirectory
    )
    runtime.register(panel: surface)
    surface.onClose = { [weak self] processAlive in
      self?.handleSurfaceClose(panelID: panel.id, processAlive: processAlive)
    }
    // C8a Phase 4d: forward `panel.initialCommand` to the freshly spawned shell so
    // `.shellEditor` launches ("$EDITOR\n") actually run. HierarchyManager.openPanel stores
    // the command on the Panel; this is the one place it gets replayed when the surface
    // comes up.
    if let initialCommand = panel.initialCommand, !initialCommand.isEmpty {
      surface.sendInput(initialCommand + "\n")
    }
    emit(.panelCreated(panel.id, tabID))
    emit(.panelReady(panel.id))
    return surface
  }

  /// Dispose a panel's surface. Idempotent. Routes through
  /// `handleSurfaceClose` so the lifecycle event is emitted exactly once
  /// whether the close is user-initiated or callback-driven.
  func closeSurface(for panelID: PanelID) {
    guard let runtime = ghosttyRuntime,
      let surface = runtime.surface(for: panelID)
    else { return }
    surface.close()
    handleSurfaceClose(panelID: panelID, processAlive: true)
  }

  /// Whether a live surface is currently registered for the panel.
  /// Used by force-remove to size the "terminate N running processes"
  /// confirmation dialog (spec W-Q3).
  func hasSurface(for panelID: PanelID) -> Bool {
    guard let runtime = ghosttyRuntime else { return false }
    return runtime.surface(for: panelID) != nil
  }

  private func handleSurfaceClose(panelID: PanelID, processAlive: Bool) {
    // Snapshot the surface state BEFORE unregistering so a stale registry
    // entry can't drop the lifecycle event. Unregister after emit so any
    // in-flight lookup in subscriber code still resolves the surface.
    let state = ghosttyRuntime?.surface(for: panelID)?.state ?? .ready
    disposeOutputBuffer(for: panelID)

    switch state {
    case .crashed(let reason):
      _ = recordPanelCrash(panelID: panelID, reason: reason)
    case .exited(let code):
      emit(.panelExited(panelID, code: code, signal: nil))
    default:
      // No explicit state set by markExited/markCrashed: use processAlive
      // to distinguish user-initiated close (code 0) from child exit where
      // we lack a real exit code (code -1 as a "unknown" sentinel).
      emit(.panelExited(panelID, code: processAlive ? 0 : -1, signal: nil))
    }

    ghosttyRuntime?.unregister(panelID: panelID)
  }

  private func tabIDForPanel(_ panelID: PanelID) -> TabID? {
    findPanel(panelID)?.tabID
  }

  /// Return a fresh event stream for a new subscriber. Multi-consumer safe:
  /// each call registers its own continuation.
  ///
  /// Output events (`panelOutput`, `panelIdle`) drop under subscriber
  /// backpressure via `.bufferingNewest(256)` — scrollback retains history
  /// so drops are recoverable. Lifecycle events are never dropped: the
  /// bounded policy only evicts output variants, and the broadcaster does
  /// not send output to `lifecycleOnly` subscribers.
  ///
  /// Subscribing after `finishEventStream()` has already been called
  /// immediately returns a finished stream.
  ///
  /// `onTermination` cleans up the registry slot asynchronously via a hop
  /// back to the MainActor; brief (~frame-ish) window where a cancelled
  /// subscriber still receives broadcasts — cheap guard.
  func events(lifecycleOnly: Bool = false) -> AsyncStream<TerminalEvent> {
    let id = UUID()
    return AsyncStream<TerminalEvent>(
      bufferingPolicy: .bufferingNewest(256)
    ) { continuation in
      if self.finished {
        continuation.finish()
        return
      }
      self.registry.subscribers.append(
        .init(id: id, continuation: continuation, lifecycleOnly: lifecycleOnly)
      )
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor in
          self?.registry.subscribers.removeAll { $0.id == id }
        }
      }
    }
  }

  /// Emit an event to all active subscribers. No-op after `finishEventStream`
  /// has been called; avoids use-after-finish footguns.
  func emit(_ event: TerminalEvent) {
    guard !finished else { return }
    registry.broadcast(event)
  }

  /// Feed bytes from a ghostty surface into the per-panel coalescer. Creates
  /// a buffer on first use. Output may split a UTF-8 codepoint at the 16KB
  /// buffer boundary — text consumers must buffer across batches per panel.
  func appendOutput(panelID: PanelID, bytes: Data) {
    let buffer = outputBuffers[panelID] ?? makeBuffer(for: panelID)
    buffer.append(bytes)
  }

  func flushOutput(for panelID: PanelID) {
    outputBuffers[panelID]?.flush()
  }

  /// Drop the per-panel output buffer, flushing any pending bytes first. The
  /// buffer's isolated-deinit fallback exists as a safety net, but callers
  /// should invoke this explicitly when a surface closes so bytes flush
  /// while the engine is still accepting emits.
  func disposeOutputBuffer(for panelID: PanelID) {
    outputBuffers[panelID]?.flush()
    outputBuffers.removeValue(forKey: panelID)
  }

  /// Idempotent, terminal. After calling, `emit` is a no-op and all
  /// subscribers receive `finish()`. Subsequent calls are safe.
  func finishEventStream() {
    guard !finished else { return }
    finished = true
    // Drain any pending output into the lifecycle-bound path before finishing.
    for (_, buffer) in outputBuffers {
      buffer.flush()
    }
    outputBuffers.removeAll()
    registry.finishAll()
  }

  // MARK: - Crash isolation

  enum CrashOutcome: Equatable, Sendable {
    /// Panel is still alive; UI should render a retry placeholder.
    case survived
    /// Enclosing Tab was auto-closed because the crash loop exceeded policy.
    case tabAutoClosed(TabID)
    /// Attempted to auto-close but `HierarchyManager.closeTab` threw; ring
    /// preserved so a later attempt can succeed. The message is the error's
    /// `localizedDescription` — callers needing the typed error should
    /// observe `HierarchyManager.catalog` for drift instead of re-throwing.
    case closeFailed(String)
  }

  @discardableResult
  func recordPanelCrash(
    panelID: PanelID,
    reason: String
  ) -> CrashOutcome {
    // Flush any buffered output so subscribers see the final bytes BEFORE the
    // crash event — otherwise the UI shows a stale prompt with the crash
    // overlay and consumers miss the last line of whatever the panel emitted.
    disposeOutputBuffer(for: panelID)
    emit(.panelCrashed(panelID, reason: reason))

    let now = clock()
    let cutoff = now.addingTimeInterval(-crashPolicy.window)
    var ring = crashRings[panelID, default: []].filter { $0 >= cutoff }
    ring.append(now)
    // Cap the ring so repeated crashes inside the window can't grow memory.
    if ring.count > crashPolicy.maxCrashesInWindow {
      ring = Array(ring.suffix(crashPolicy.maxCrashesInWindow))
    }
    crashRings[panelID] = ring

    guard ring.count >= crashPolicy.maxCrashesInWindow else {
      return .survived
    }

    guard let location = findPanel(panelID) else {
      crashRings.removeValue(forKey: panelID)
      return .survived
    }

    // Snapshot sibling panels BEFORE closeTab removes them. Each gets its
    // own panelExited event so per-panel subscribers can release state.
    let siblingPanelIDs = siblingPanelIDs(in: location, excluding: panelID)

    do {
      try hierarchy.closeTab(
        location.tabID,
        in: location.worktreeID,
        in: location.projectID,
        in: location.spaceID
      )
    } catch {
      // Preserve the ring so a retry can still close the tab.
      return .closeFailed(error.localizedDescription)
    }

    crashRings.removeValue(forKey: panelID)
    let cause: TabAutoCloseCause = .crashLoop(count: ring.count, window: crashPolicy.window)
    for siblingID in siblingPanelIDs {
      disposeOutputBuffer(for: siblingID)
      // Forced close, not clean exit — distinct variant so persistence and
      // C3 hook consumers don't misreport as code-0 exit.
      emit(.panelClosedByTab(siblingID, cause: cause))
    }
    emit(.tabAutoClosed(location.tabID, cause: cause))
    return .tabAutoClosed(location.tabID)
  }

  /// Retry a crashed panel. Returns false when the panel no longer exists
  /// (e.g. its Tab was already auto-closed). M5 replaces the stub body with
  /// real surface recreation via GhosttyRuntime.createSurface.
  @discardableResult
  func retryPanel(_ panelID: PanelID) -> Bool {
    guard findPanel(panelID) != nil else {
      return false
    }
    crashRings.removeValue(forKey: panelID)
    emit(.panelReady(panelID))
    return true
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

  private func siblingPanelIDs(
    in location: PanelLocation,
    excluding excluded: PanelID
  ) -> [PanelID] {
    guard
      let space = hierarchy.catalog.spaces.first(where: { $0.id == location.spaceID }),
      let project = space.projects.first(where: { $0.id == location.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == location.worktreeID }),
      let tab = worktree.tabs.first(where: { $0.id == location.tabID })
    else {
      return []
    }
    return tab.panels.map(\.id).filter { $0 != excluded }
  }

  private func makeBuffer(for panelID: PanelID) -> PendingOutputBuffer {
    // The engine must outlive its output buffers. disposeOutputBuffer drops
    // the buffer while the engine is still broadcasting, so the weak capture
    // only matters as a safety net if the buffer is dropped via deinit after
    // finishEventStream — in that case emit is a no-op, bytes silently fall
    // on the floor (documented trade-off).
    let buffer = PendingOutputBuffer(panelID: panelID) { [weak self] id, data in
      self?.emit(.panelOutput(id, data))
    }
    outputBuffers[panelID] = buffer
    return buffer
  }
}

extension TerminalEvent {
  /// Lifecycle events must not drop under consumer backpressure — they drive
  /// persistence and TCA state machines. Output events are safe to drop
  /// because scrollback retains history.
  fileprivate var isLifecycle: Bool {
    switch self {
    case .panelOutput, .panelIdle:
      return false
    case .panelCreated, .panelReady, .panelExited, .panelCrashed,
      .panelClosedByTab, .tabActivated, .tabAutoClosed,
      .worktreeActivated, .hierarchyMutated:
      return true
    }
  }
}
