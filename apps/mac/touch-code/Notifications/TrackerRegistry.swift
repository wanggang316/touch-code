import Foundation
import TouchCodeCore

/// Single owner of `AgentStateTracker` lifetimes across the whole C6 plan
/// (DEC-P2). Created at app-shell launch after `HierarchyManager.load()`;
/// the app shell calls `bootstrap()` once so pre-existing agent-labelled
/// Panes get trackers before `DetectionRouter` starts receiving envelopes.
/// Subsequent Pane additions/removals/label changes flow through
/// `create(for:)` / `destroy(for:)`, driven by the coordinator (M4b) from
/// `HierarchyManager` callbacks.
///
/// A Pane is considered agent-hosted iff any of its `labels` starts with
/// `"agent:"` — matches the CLI convention `tc label <pane> --agent <name>`
/// (see design §Known-Agent Rule Templates).
@MainActor
final class TrackerRegistry {
  /// Read-only access to the manager the registry observes. Exposed so
  /// the M7 integration harness can hand the same catalog closure to
  /// `HookDispatcher.attach(to:catalog:)` without re-plumbing the
  /// manager through C6AppBootstrap.
  let hierarchy: HierarchyManager
  private(set) var idleThreshold: TimeInterval
  private let clock: any Clock<Duration>
  private var trackers: [PaneID: AgentStateTracker] = [:]
  private let (creationStream, creationContinuation): (AsyncStream<PaneID>, AsyncStream<PaneID>.Continuation)

  init(
    hierarchy: HierarchyManager,
    idleThreshold: TimeInterval,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.hierarchy = hierarchy
    self.idleThreshold = idleThreshold
    self.clock = clock
    let (stream, continuation) = AsyncStream<PaneID>.makeStream()
    self.creationStream = stream
    self.creationContinuation = continuation
  }

  deinit {
    creationContinuation.finish()
    // Individual trackers are MainActor-isolated; their own deinit finishes
    // their streams. Registry drop-out does not require explicit teardown
    // here and cannot call MainActor methods from a nonisolated deinit.
  }

  /// Scan `hierarchy.catalog` for every Pane whose labels contain an
  /// `"agent:"`-prefixed entry and create a tracker for each. Idempotent
  /// on repeat calls (existing trackers are preserved). Must be called
  /// exactly once before `DetectionRouter.handle(envelope:)` runs.
  func bootstrap() {
    for pane in Self.agentLabelledPanes(in: hierarchy.catalog) {
      _ = create(for: pane.id)
    }
  }

  /// Lookup — returns nil for Panes without an agent label. `DetectionRouter`
  /// calls this per envelope; a nil result means the envelope is dropped
  /// with a log entry (no silent creation).
  func tracker(for paneID: PaneID?) -> AgentStateTracker? {
    guard let paneID else { return nil }
    return trackers[paneID]
  }

  /// Every live tracker. The coordinator iterates this at launch (step 10
  /// of the plan's app-shell wiring) to invoke `onAgentPaneCreated` per
  /// pre-existing agent Pane.
  var allTrackers: [AgentStateTracker] { Array(trackers.values) }

  /// Stream of tracker-creation events — the coordinator subscribes to
  /// drive `onAgentPaneCreated` for Panes added during the session.
  var trackerCreations: AsyncStream<PaneID> { creationStream }

  /// Create a tracker for the given Pane. Idempotent; re-invocations with
  /// the same `paneID` return the existing tracker without yielding a
  /// duplicate on `trackerCreations`.
  @discardableResult
  func create(for paneID: PaneID) -> AgentStateTracker {
    if let existing = trackers[paneID] { return existing }
    let tracker = AgentStateTracker(
      paneID: paneID,
      idleThreshold: idleThreshold,
      clock: clock
    )
    trackers[paneID] = tracker
    creationContinuation.yield(paneID)
    return tracker
  }

  /// Tear down the tracker for the given Pane. Called when the Pane is
  /// removed from the hierarchy or loses its agent label. No-op if the
  /// Pane has no tracker.
  func destroy(for paneID: PaneID) {
    guard let tracker = trackers.removeValue(forKey: paneID) else { return }
    tracker.teardown()
  }

  /// Adopt a new idle threshold from a rule reload. Stores the value so
  /// future `create(for:)` calls receive the new threshold, and
  /// propagates to every live tracker so already-running Panes pick up
  /// the change without a restart.
  func updateIdleThreshold(_ seconds: TimeInterval) {
    idleThreshold = seconds
    for tracker in trackers.values {
      tracker.updateIdleThreshold(seconds)
    }
  }

  // MARK: - Catalog walk

  /// Flatten the five-level hierarchy to the Panes whose labels mark them
  /// as agent-hosted. Exposed as a static so tests can exercise it without
  /// building a full HierarchyManager.
  static func agentLabelledPanes(in catalog: Catalog) -> [Pane] {
    var result: [Pane] = []
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            for pane in tab.panes where pane.labels.contains(where: { $0.hasPrefix("agent:") }) {
              result.append(pane)
            }
          }
        }
      }
    }
    return result
  }
}
