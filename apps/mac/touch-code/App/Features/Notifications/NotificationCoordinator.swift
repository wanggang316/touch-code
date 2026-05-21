import Foundation
import TouchCodeCore
import os.log

/// Central chokepoint for v1.1 notifications. Every `Candidate` the detector
/// produces flows through `handle(_:)`, which gates against the four
/// settings.json toggles (`inAppEnabled`, `systemEnabled`, `soundEnabled`,
/// `dockBadgeEnabled`), routes the live banner through `OSNotifier`, and
/// updates the Dock badge mirror in lockstep with the inbox.
///
/// The class is intentionally test-friendly: collaborators are protocols /
/// closures, the public `Decision` return value carries enough detail for
/// tests to assert outcomes without scraping mock collaborators, and the
/// settings + authorization snapshot is read at decision time rather than
/// captured at construction so a same-tick toggle flip is honoured.
///
/// M4.T1 will lift the `DropReason` enum into `TouchCodeCore.InboxDropReason`
/// (shared with `DetectionTranslator.Step.drop`); the case names are pinned
/// so the lift is mechanical.
@MainActor
final class NotificationCoordinator {
  private let inbox: NotificationStore
  private let osNotifier: any OSNotifier
  private let settingsReader: any NotificationSettingsReader
  // swiftlint:disable:next unused_declaration
  private let catalog: HierarchyClient
  private let now: @MainActor () -> Date
  private let logger = Logger(
    subsystem: "com.touch-code.notifications",
    category: "coordinator"
  )

  /// Unread count per worktree, maintained alongside `inbox` mutations. M6.T2
  /// will consume this to drive the "promote notified worktree to top"
  /// behaviour; for M2.T2 it is observable for tests only.
  internal private(set) var unreadByWorktree: [WorktreeID: Int] = [:]

  /// Test seam: drop reasons logged on the most recent `handle(_:)` call.
  /// Reset at the top of every `handle` invocation. Production reads only
  /// the `Decision` return value; this exists so test L-001 can assert the
  /// log-emitting code path was exercised without intercepting `os.Logger`.
  internal private(set) var lastDropReasons: [DropReason] = []

  init(
    inbox: NotificationStore,
    osNotifier: any OSNotifier,
    settingsReader: any NotificationSettingsReader,
    catalog: HierarchyClient,
    now: @MainActor @escaping () -> Date = { Date() }
  ) {
    self.inbox = inbox
    self.osNotifier = osNotifier
    self.settingsReader = settingsReader
    self.catalog = catalog
    self.now = now

    // Bootstrap the unread-per-worktree cache from any inbox entries that
    // were rehydrated from disk. Without this, a process restart with
    // persisted unread entries would leave the cache at zero and the M6.T2
    // promotion logic would never fire until a brand-new notification
    // landed on that worktree.
    for entry in inbox.entries where entry.isUnread {
      unreadByWorktree[entry.source.worktreeID, default: 0] += 1
    }
  }

  /// Every candidate notification passes through here. Returns the decision
  /// so tests can inspect what happened without scraping mock collaborators.
  @discardableResult
  func handle(_ candidate: Candidate) async -> Decision {
    lastDropReasons = []

    if candidate.sourceIsFocused {
      logger.debug("drop sourceIsFocused")
      lastDropReasons.append(.sourceIsFocused)
      return .dropped(reason: .sourceIsFocused)
    }

    let settings = settingsReader.notifications
    let auth = settingsReader.authStatus

    // Inbox path. `inbox.append` may dedup (same paneID+kind within 30 s
    // merges into the prior entry preserving its `readAt`) or evict an
    // unread row when the 500-cap is hit. Both outcomes mean the
    // per-worktree unread count did NOT actually grow on this call, so
    // we read the canonical count from `inbox.entries` before and after
    // the append and report the actual delta. The cache mirrors the
    // post-append truth so M6.T2's promote logic sees a faithful 0→N
    // edge rather than an inflated synthetic one.
    let didAppend: Bool
    if settings.inAppEnabled {
      let worktreeID = candidate.entry.source.worktreeID
      let before = unreadCount(inWorktree: worktreeID)
      inbox.append(candidate.entry)
      let after = unreadCount(inWorktree: worktreeID)
      unreadByWorktree[worktreeID] = after
      didAppend = (after > before)
    } else {
      didAppend = false
      logger.debug("drop inAppDisabled (inbox not appended)")
      lastDropReasons.append(.inAppDisabled)
    }

    // Dock badge path. `recomputeDockBadge` is the single function that
    // honours both `inAppEnabled` and `dockBadgeEnabled`, so we call it
    // unconditionally on every `handle` — defense in depth against any
    // path that mutates inbox state without going through the
    // `dockBadgerTask` mirror or the settings `onChange` subscription.
    // `didBadge` reflects the user-visible truth: the badge changed only
    // when the inbox actually grew AND the dock surface is enabled.
    recomputeDockBadge()
    let didBadge = didAppend && settings.dockBadgeEnabled

    // OS banner path. Independent of `inAppEnabled` by design — the user
    // can run banner-only, inbox-only, both, or neither.
    let didPost: Bool
    let didSound: Bool
    if settings.systemEnabled {
      if auth == .authorized {
        await osNotifier.post(candidate.entry, playSound: settings.soundEnabled)
        didPost = true
        didSound = settings.soundEnabled
      } else {
        didPost = false
        didSound = false
        logger.debug("drop authorizationDenied")
        lastDropReasons.append(.authorizationDenied)
      }
    } else {
      didPost = false
      didSound = false
      logger.debug("drop systemDisabled")
      lastDropReasons.append(.systemDisabled)
    }

    // Promote path: stubbed for M2.T2. M6.T2 will read `unreadByWorktree`
    // and `settings.moveNotifiedWorktreeToTop`, and call
    // `catalog.reorderWorktrees(...)` when the worktree was previously at
    // zero unread (i.e. this notification is what lit it up).
    // swiftlint:disable:next todo
    // TODO(M6.T2): wire promote via catalog.reorderWorktrees.
    let didPromote = false

    return .posted(
      inAppAppended: didAppend,
      osBannerPosted: didPost,
      soundPlayed: didSound,
      badgeUpdated: didBadge,
      promoted: didPromote
    )
  }

  /// Recomputes the Dock badge label from the live inbox unread count,
  /// honouring both `inAppEnabled` (no inbox surface → no badge) and
  /// `dockBadgeEnabled` (badge surface explicitly off).
  func recomputeDockBadge() {
    let settings = settingsReader.notifications
    if !settings.inAppEnabled || !settings.dockBadgeEnabled {
      DockBadger.setBadge(0)
    } else {
      DockBadger.setBadge(inbox.unreadCount)
    }
  }

  /// Re-reads the OS authorization status. AppState wires this at app start
  /// and on `applicationDidBecomeActive`. No-op when `settingsReader` is not
  /// the concrete `SettingsStoreReaderAdapter` (tests use the fake reader
  /// and set `authStatus` directly).
  func refreshAuthorizationStatus() async {
    if let adapter = settingsReader as? SettingsStoreReaderAdapter {
      await adapter.refresh()
    }
  }

  // MARK: - Internals

  /// Per-worktree unread count read off the canonical inbox. Called twice
  /// per `handle` invocation to compute the actual append delta after
  /// `inbox.append` (which may dedup within 30 s or evict an unread row on
  /// the 500-cap eviction). O(N) over `inbox.entries`; N is capped at 500
  /// by `InboxStorage.cap`, so the per-append cost is well inside the
  /// MainActor budget.
  private func unreadCount(inWorktree worktreeID: WorktreeID) -> Int {
    inbox.entries.reduce(0) { acc, entry in
      acc + (entry.source.worktreeID == worktreeID && entry.isUnread ? 1 : 0)
    }
  }

  // MARK: - Nested types

  /// A candidate notification produced by `NotificationDetector`. The
  /// `sourceIsFocused` flag is pre-computed by the detector because it
  /// already has to walk the catalog to enrich the title; passing it
  /// through avoids a second walk inside the coordinator.
  struct Candidate: Equatable, Sendable {
    let entry: InboxEntry
    /// True iff the source pane equals the user's globally-focused pane.
    let sourceIsFocused: Bool
  }

  /// Outcome of `handle(_:)`. `.posted` always carries the full bool tuple
  /// so a single decision can describe asymmetric outcomes (e.g. "appended
  /// to the inbox but the system banner was suppressed because the user
  /// turned off `systemEnabled`"). `.dropped` is reserved for the single
  /// gate that suppresses every surface — the source pane being focused.
  enum Decision: Equatable, Sendable {
    case posted(
      inAppAppended: Bool,
      osBannerPosted: Bool,
      soundPlayed: Bool,
      badgeUpdated: Bool,
      promoted: Bool
    )
    case dropped(reason: DropReason)
  }

  /// Local to M2.T2. M4.T1 will lift this into
  /// `TouchCodeCore.InboxDropReason` (shared with
  /// `DetectionTranslator.Step.drop`). Case names are pinned so the lift is
  /// mechanical. `paneMuted`, `commandFinishedDisabled`,
  /// `commandFinishedShort`, `commandCancelled`, `userTypingRecently` are
  /// reserved for the translator log line — the coordinator itself does not
  /// emit them today.
  enum DropReason: String, Equatable, Sendable {
    case sourceIsFocused
    case inAppDisabled
    case systemDisabled
    case paneMuted
    case commandFinishedDisabled
    case commandFinishedShort
    case commandCancelled
    case userTypingRecently
    case authorizationDenied
  }
}
