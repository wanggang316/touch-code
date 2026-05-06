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

  /// Cached `(projectID, worktreeID, tabID, paneID)` per pane so a
  /// terminal `paneExited` / `paneCrashed` event can still produce a
  /// notification even when `RootFeature`'s parallel event consumer
  /// has already called `closePane` and removed the pane from the
  /// live catalog. Updated whenever a live catalog walk succeeds;
  /// cleared on the pane's lifecycle teardown events.
  private var paneSourceCache: [PaneID: InboxEntry.SourcePath] = [:]

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

  /// The single globally focused pane — the pane the user is *actually*
  /// looking at right now. Composed from the active project → active
  /// worktree → active tab → that tab's last-focused split, and only
  /// when the app itself is frontmost. There is at most one such pane
  /// at any moment; `nil` means "the user is not looking at any pane"
  /// (app backgrounded, no selection, sidebar focus, etc.).
  ///
  /// Notifications whose source matches this pane are dropped entirely:
  /// no inbox row, no banner, no badge — the user is already eyeballing
  /// the in-pane output.
  private func globallyFocusedPane() -> PaneID? {
    guard isAppFrontmost() else { return nil }
    let catalog = catalogSnapshot()
    guard let activeProjectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == activeProjectID }),
      let worktreeID = project.selectedWorktreeID,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let tabID = worktree.selectedTabID
    else { return nil }
    return lastFocusedPane(tabID)
  }

  /// Single entry point. Called for every `TerminalEvent` the runtime
  /// emits. The translation table itself lives in
  /// `TouchCodeCore.DetectionTranslator` (pure, fully unit-tested);
  /// this method orchestrates: catalog walk → SourcePath, mute label
  /// check, store.append, banner gating.
  public func handle(_ event: TerminalEvent) async {
    let step = DetectionTranslator.translate(event, hasProducedOutput: hasProducedOutput)

    switch step.outputFlag {
    case .markProduced(let paneID):
      hasProducedOutput.insert(paneID)
      // Refresh the source-path cache while the pane is still live in
      // the catalog. By the time a future paneExited event flows through
      // here, RootFeature's parallel consumer may have removed the pane;
      // the cache means we still know where it lived.
      _ = liveResolve(paneID: paneID)
    case .clearProduced(let paneID):
      hasProducedOutput.remove(paneID)
    // Don't drop cache here — `emit` for the same teardown event still
    // needs to look up the source path. Cache is dropped at the end of
    // `emit` once we've actually used it.
    case .unchanged:
      break
    }

    guard let entry = step.entry else { return }
    await emit(entry, isTeardown: step.outputFlag.isTeardown)
  }

  private func emit(_ translated: DetectionTranslator.Entry, isTeardown: Bool) async {
    guard let resolved = resolve(paneID: translated.paneID) else { return }
    if resolved.muted { return }

    // Drop entirely when the source pane is the user's currently
    // globally-focused pane: the user is already looking at the
    // in-pane output, so an inbox row + dock badge bump + banner
    // would all be noise. There is at most one globally-focused
    // pane at any time (see `globallyFocusedPane` doc), so this is
    // not symmetric with the per-tab last-focused behaviour: a
    // notification fired from a non-active tab's last-focused
    // split *will* notify, because by definition the user isn't
    // looking at it.
    if resolved.source.paneID == globallyFocusedPane() {
      return
    }

    // Enrich the title with the originating worktree's display name so
    // a banner reads `[main] Pane bell` rather than just `Pane bell` —
    // critical when the user has multiple worktrees backgrounded and
    // needs to triage at a glance.
    let enrichedTitle = resolved.worktreeLabel.map { "[\($0)] \(translated.title)" } ?? translated.title
    let inbox = InboxEntry(
      kind: translated.kind,
      title: enrichedTitle,
      body: translated.body,
      source: resolved.source
    )
    store.append(inbox)

    // Banner gating reduces to "always banner if we got past the
    // global-focus drop above" — the focused-pane case is already
    // suppressed. macOS will still suppress the banner UI itself
    // when the app is foreground and presenting; the inbox + dock
    // badge are the in-app surfaces.
    await banner.post(inbox)

    // Drop the cache only after the entry has been emitted. A teardown
    // event (paneExited / paneCrashed / paneClosedByTab) still needs
    // the cached source path to resolve, but no future event for this
    // pane id will ever arrive again — clean up.
    if isTeardown {
      paneSourceCache.removeValue(forKey: translated.paneID)
    }
  }

  // MARK: - Helpers

  /// Resolve `paneID` to source path + mute state + worktree label.
  /// Tries the live catalog first; falls back to `paneSourceCache` when
  /// the pane has already been removed from the catalog (typical on
  /// `paneExited`: `RootFeature.paneLifecycleExited` may have closed it
  /// before this consumer runs). Returns nil only when both the live
  /// catalog and the cache have nothing — meaning the pane never had
  /// any prior catalog presence in this process. Cache fallback path
  /// loses worktreeLabel + mute info; that's an acceptable trade for
  /// not silently swallowing the final teardown notification.
  private func resolve(
    paneID: PaneID
  ) -> (source: InboxEntry.SourcePath, muted: Bool, worktreeLabel: String?)? {
    if let live = liveResolve(paneID: paneID) {
      return live
    }
    if let cached = paneSourceCache[paneID] {
      return (cached, false, nil)
    }
    return nil
  }

  /// Live-catalog resolve. On success, refreshes `paneSourceCache` so
  /// later teardown events still have a valid source after the pane
  /// has been removed from the catalog.
  @discardableResult
  private func liveResolve(
    paneID: PaneID
  ) -> (source: InboxEntry.SourcePath, muted: Bool, worktreeLabel: String?)? {
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
          paneSourceCache[paneID] = source
          let label = worktree.name.isEmpty ? nil : worktree.name
          return (source, pane.labels.contains(InboxLabels.muted), label)
        }
      }
    }
    return nil
  }

}
