import AppKit
import Foundation
import TouchCodeCore

/// Translates the runtime's structured `TerminalEvent` stream into
/// `InboxEntry` rows and routes them to `NotificationStore` plus a
/// macOS banner (when the user is not already looking at the source).
///
/// This is *not* a stdout regex scanner — it consumes only the typed
/// events libghostty + the engine already publish: OSC 9 desktop
/// notifications, terminal bell, OSC 133 `commandFinished`,
/// `paneExited`, `paneCrashed`, and `paneIdle`. Tools that don't emit
/// any of these are silently uncovered; this is a documented v1 trade-off.
///
/// `RootFeature.engineEventReceived` calls `handle(_:)` for every
/// runtime event so the detector lives downstream of the existing
/// single-consumer event loop and does not need its own subscription.
@MainActor
public final class NotificationDetector {
  /// Idle threshold below which `paneIdle` events are ignored. Matches
  /// `InboxStorage.dedupWindow` — the runtime emits idle ticks at a
  /// shorter cadence than this for cursor-blink and similar non-events;
  /// 30 s is the lower bound for "this pane has actually gone quiet".
  public static let idleThreshold: TimeInterval = 30

  private let store: NotificationStore
  private let banner: OSNotifier
  private let catalogSnapshot: @MainActor () -> Catalog
  private let lastFocusedPane: @MainActor (TabID) -> PaneID?
  private let isAppFrontmost: @MainActor () -> Bool

  /// Panes that have produced any `paneOutput` since launch (or since the
  /// last time their child exited). Gates `paneIdle` so a freshly spawned
  /// pane that has never produced output cannot fire a `taskFinished`.
  private var hasProducedOutput: Set<PaneID> = []

  public init(
    store: NotificationStore,
    banner: OSNotifier,
    catalogSnapshot: @escaping @MainActor () -> Catalog,
    lastFocusedPane: @escaping @MainActor (TabID) -> PaneID?,
    isAppFrontmost: @escaping @MainActor () -> Bool = { NSApp.isActive }
  ) {
    self.store = store
    self.banner = banner
    self.catalogSnapshot = catalogSnapshot
    self.lastFocusedPane = lastFocusedPane
    self.isAppFrontmost = isAppFrontmost
  }

  /// Single entry point. Called for every `TerminalEvent` the runtime
  /// emits. Internally fans into the relevant `InboxEntry.Kind`
  /// translations and drops events that don't carry notification value.
  public func handle(_ event: TerminalEvent) async {
    switch event {
    case .paneOutput(let paneID, _):
      hasProducedOutput.insert(paneID)

    case .paneInfoChanged(let paneID, let delta):
      switch delta {
      case .desktopNotification(let title, let body):
        await emit(paneID: paneID, kind: classify(title: title, body: body), title: title, body: body)
      case .bellRang:
        await emit(
          paneID: paneID,
          kind: .waitingForInput,
          title: "Pane bell",
          body: "A pane rang the terminal bell."
        )
      case .commandFinished(let exitCode, _):
        await emit(
          paneID: paneID,
          kind: .taskFinished,
          title: "Command finished",
          body: exitCode == 0
            ? "Command completed successfully."
            : "Command exited with status \(exitCode)."
        )
      default:
        break
      }

    case .paneExited(let paneID, let code, let signal):
      let body: String
      if let signal {
        body = "Pane terminated by signal \(signal)."
      } else if code == 0 {
        body = "Pane exited cleanly."
      } else {
        body = "Pane exited with status \(code)."
      }
      await emit(paneID: paneID, kind: .taskFinished, title: "Pane exited", body: body)
      hasProducedOutput.remove(paneID)

    case .paneCrashed(let paneID, let reason):
      await emit(paneID: paneID, kind: .taskFinished, title: "Pane crashed", body: reason)
      hasProducedOutput.remove(paneID)

    case .paneIdle(let paneID, let duration):
      guard duration >= Self.idleThreshold, hasProducedOutput.contains(paneID) else { return }
      await emit(
        paneID: paneID,
        kind: .taskFinished,
        title: "Pane idle",
        body: "No output for \(Int(duration.rounded())) s."
      )

    case .paneClosedByTab, .paneCreated, .paneReady,
      .tabActivated, .tabAutoClosed, .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      break
    }
  }

  // MARK: - Translation

  /// Maps a desktop-notification title/body onto an `InboxEntry.Kind`. The
  /// heuristic is intentionally simple: matches the words "permission",
  /// "approval", "approve", "input" or a trailing question mark — all of
  /// which strongly imply the agent is blocked on the user. Anything else
  /// becomes `.taskFinished`.
  private func classify(title: String, body: String) -> InboxEntry.Kind {
    let combined = (title + " " + body).lowercased()
    let cues = ["permission", "approval", "approve", "input", "?"]
    if cues.contains(where: combined.contains) {
      return .waitingForInput
    }
    return .taskFinished
  }

  private func emit(
    paneID: PaneID,
    kind: InboxEntry.Kind,
    title: String,
    body: String
  ) async {
    guard let source = resolveSource(paneID: paneID) else { return }
    if isMuted(paneID: paneID) { return }

    let entry = InboxEntry(kind: kind, title: title, body: body, source: source)
    store.append(entry)

    if shouldBanner(source: source) {
      await banner.post(entry)
    }
  }

  // MARK: - Helpers

  /// Walks the catalog to recover the full `(P, W, T, Pn)` for `paneID`.
  /// Returns nil when the pane is not yet in the catalog (e.g. a stray
  /// event arriving before the engine has wired the pane to a tab).
  private func resolveSource(paneID: PaneID) -> InboxEntry.SourcePath? {
    let catalog = catalogSnapshot()
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.flatPaneIDs.contains(paneID) {
          return InboxEntry.SourcePath(
            projectID: project.id,
            worktreeID: worktree.id,
            tabID: tab.id,
            paneID: paneID
          )
        }
      }
    }
    return nil
  }

  /// A pane is muted when its `Pane.labels` contains `"notifications:muted"`.
  /// Per-pane mute is the only mute knob in v1.
  private func isMuted(paneID: PaneID) -> Bool {
    let catalog = catalogSnapshot()
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          if let pane = tab.panes.first(where: { $0.id == paneID }) {
            return pane.labels.contains("notifications:muted")
          }
        }
      }
    }
    return false
  }

  /// Banner gating: deliver when **either** the app is not frontmost **or**
  /// the source pane is not the user's currently focused pane. When the
  /// user is already looking at the pane there's no benefit to banner-ing
  /// them — the in-pane output is the alert.
  private func shouldBanner(source: InboxEntry.SourcePath) -> Bool {
    if !isAppFrontmost() { return true }
    let focused = lastFocusedPane(source.tabID)
    return focused != source.paneID
  }
}
