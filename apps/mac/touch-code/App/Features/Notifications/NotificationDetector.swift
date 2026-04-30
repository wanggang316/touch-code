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
  /// emits. The translation table itself lives in
  /// `TouchCodeCore.DetectionTranslator` (pure, fully unit-tested);
  /// this method orchestrates: catalog walk → SourcePath, mute label
  /// check, store.append, banner gating.
  public func handle(_ event: TerminalEvent) async {
    let step = DetectionTranslator.translate(event, hasProducedOutput: hasProducedOutput)

    switch step.outputFlag {
    case .markProduced(let paneID): hasProducedOutput.insert(paneID)
    case .clearProduced(let paneID): hasProducedOutput.remove(paneID)
    case .unchanged: break
    }

    guard let entry = step.entry else { return }
    await emit(entry)
  }

  private func emit(_ translated: DetectionTranslator.Entry) async {
    guard let resolved = resolve(paneID: translated.paneID) else { return }
    if resolved.muted { return }

    let inbox = InboxEntry(
      kind: translated.kind,
      title: translated.title,
      body: translated.body,
      source: resolved.source
    )
    store.append(inbox)

    if shouldBanner(source: resolved.source) {
      await banner.post(inbox)
    }
  }

  // MARK: - Helpers

  /// Single-pass catalog walk that resolves `paneID` to its full source
  /// path AND its mute state in one O(N) traversal — previously two
  /// independent walks called per event. Returns nil when the pane is
  /// not yet in the catalog (e.g. a stray event arriving before the
  /// engine has wired the pane to a tab).
  private func resolve(paneID: PaneID) -> (source: InboxEntry.SourcePath, muted: Bool)? {
    let catalog = catalogSnapshot()
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          guard let pane = tab.panes.first(where: { $0.id == paneID }) else { continue }
          let source = InboxEntry.SourcePath(
            projectID: project.id,
            worktreeID: worktree.id,
            tabID: tab.id,
            paneID: pane.id
          )
          return (source, pane.labels.contains(InboxLabels.muted))
        }
      }
    }
    return nil
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
