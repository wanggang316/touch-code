import Foundation
import Observation
import os.log
import TouchCodeCore

/// Persistent store for `AgentNotification`s under `~/.config/touch-code/notifications.json`.
///
/// Mirrors `CatalogStore` in pattern: atomic-rename JSON via `AtomicFileStore`,
/// 500ms debounced trailing saves, synchronous flush via `saveNow` on app
/// termination. Enforces the design doc's 500-row hard cap on append and the
/// 7-day soft-delete sweep on load. The Dock-badge count (DEC-13) reads
/// `unreadCount` directly; `unreadPublisher` yields on every mutation so the
/// M4 coordinator can mirror the badge without polling.
@MainActor
@Observable
final class InboxStore {
  private(set) var inbox: NotificationInbox = .empty

  private let fileURL: URL
  private let clock: any Clock<Duration>
  private let debounce: Duration
  private let logger = Logger(subsystem: "com.touch-code.notifications", category: "inbox")

  // `@ObservationIgnored` on internal bookkeeping that the nonisolated
  // `deinit` touches — `@Observable` would otherwise require those reads
  // to hop to the MainActor, which `deinit` cannot do.
  @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
  private let unreadContinuation: AsyncStream<Int>.Continuation
  private let unreadStream: AsyncStream<Int>

  /// Multi-subscriber inbox mutation stream. Each call to `observeInbox()`
  /// creates a fresh `AsyncStream<NotificationInbox>` registered by a
  /// unique id, yields the current inbox immediately (so the subscriber
  /// sees initial state without polling), and is fanned into on every
  /// mutation. C6 M5 `InboxClient.observe()` consumes this; future
  /// settings-pane surfaces may add more subscribers without stepping on
  /// each other.
  @ObservationIgnored
  private var inboxSubscribers: [UUID: AsyncStream<NotificationInbox>.Continuation] = [:]

  /// Design DEC-9 — 500-row retained cap.
  static let retentionCap = 500

  /// Design DEC-9 — 7-day soft-delete sweep window.
  static let softDeleteWindow: TimeInterval = 7 * 24 * 60 * 60

  init(
    fileURL: URL = ConfigPaths.notificationInbox(),
    clock: any Clock<Duration> = ContinuousClock(),
    debounce: Duration = .milliseconds(500)
  ) {
    self.fileURL = fileURL
    self.clock = clock
    self.debounce = debounce
    (self.unreadStream, self.unreadContinuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  deinit {
    pendingSaveTask?.cancel()
    unreadContinuation.finish()
    for (_, continuation) in inboxSubscribers {
      continuation.finish()
    }
  }

  // MARK: - Load

  /// Read the inbox from disk. Returns `.empty` on ENOENT. On unknown-version or
  /// decode failure, backs the broken file up to `notifications.json.broken-<ISO8601>`
  /// and returns `.empty`. Applies the 7-day sweep before returning.
  @discardableResult
  func load(now: Date = Date()) throws -> NotificationInbox {
    let loaded: NotificationInbox
    do {
      loaded = try AtomicFileStore.read(NotificationInbox.self, at: fileURL) ?? .empty
    } catch NotificationInbox.DecodingIssue.unsupportedVersion(let v) {
      logger.error("Unsupported notifications.json version \(v); backing up and starting empty.")
      backupBrokenFile()
      loaded = .empty
    } catch {
      logger.error("Failed to decode notifications.json: \(String(describing: error)); backing up and starting empty.")
      backupBrokenFile()
      loaded = .empty
    }
    inbox = Self.applySweep(loaded, now: now)
    publishMutation()
    return inbox
  }

  // MARK: - Mutations

  /// Insert at index 0, enforce 500-row cap, schedule debounced save, publish unread.
  func append(_ notification: AgentNotification) {
    inbox.notifications.insert(notification, at: 0)
    if inbox.notifications.count > Self.retentionCap {
      inbox.notifications.removeLast(inbox.notifications.count - Self.retentionCap)
    }
    scheduleSave()
    publishMutation()
  }

  /// Mark each matching entry as read (sets `readAt = now` if not already read).
  func markRead(_ ids: [UUID], now: Date = Date()) {
    let idSet = Set(ids)
    guard !idSet.isEmpty else { return }
    var mutated = false
    for index in inbox.notifications.indices where idSet.contains(inbox.notifications[index].id) {
      if inbox.notifications[index].readAt == nil {
        inbox.notifications[index].readAt = now
        mutated = true
      }
    }
    if mutated {
      scheduleSave()
      publishMutation()
    }
  }

  /// Soft-delete each matching entry (sets `dismissedAt = now`). Dismissed entries
  /// remain in the inbox for 7 days per DEC-9, after which `load()`'s sweep removes them.
  func dismiss(_ ids: [UUID], now: Date = Date()) {
    let idSet = Set(ids)
    guard !idSet.isEmpty else { return }
    var mutated = false
    for index in inbox.notifications.indices where idSet.contains(inbox.notifications[index].id) {
      if inbox.notifications[index].dismissedAt == nil {
        inbox.notifications[index].dismissedAt = now
        mutated = true
      }
    }
    if mutated {
      scheduleSave()
      publishMutation()
    }
  }

  /// Marks every notification whose panel resolves (through `catalog`) to
  /// the given Worktree as read. `readAt` is set to `now` for any entry
  /// that was previously unread and mapped to the worktree. Skips entries
  /// whose panel is no longer in the catalog. If anything changed, schedules
  /// a debounced save and publishes the unread mutation so the Dock badge
  /// updates. Idempotent: a second call on an already-read set is a no-op.
  func markRead(forWorktree worktreeID: WorktreeID, in catalog: Catalog, now: Date = Date()) {
    let panelIDs = catalog.panelIDs(inWorktree: worktreeID)
    guard !panelIDs.isEmpty else { return }
    var mutated = false
    for index in inbox.notifications.indices {
      guard panelIDs.contains(inbox.notifications[index].panelID) else { continue }
      guard inbox.notifications[index].readAt == nil else { continue }
      inbox.notifications[index].readAt = now
      mutated = true
    }
    if mutated {
      scheduleSave()
      publishMutation()
    }
  }

  /// Canonical name for the "Dismiss all" header action. `clearAll` is a
  /// legacy alias kept to avoid C6 M5 caller churn and may be removed in T2
  /// once the bell popover replaces the inbox sidebar.
  func dismissAll(now: Date = Date()) {
    clearAll(now: now)
  }

  /// Dismiss every entry in the inbox. Counterpart to the "Clear all" header action.
  /// Legacy alias of `dismissAll`; see T0 design doc. Call sites in C6 M5 still use
  /// `clearAll`; new call sites should prefer `dismissAll`.
  func clearAll(now: Date = Date()) {
    var mutated = false
    for index in inbox.notifications.indices where inbox.notifications[index].dismissedAt == nil {
      inbox.notifications[index].dismissedAt = now
      mutated = true
    }
    if mutated {
      scheduleSave()
      publishMutation()
    }
  }

  // MARK: - Persistence

  /// Synchronous flush; called by the app shell on `applicationWillTerminate`.
  func saveNow() throws {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    try AtomicFileStore.write(inbox, to: fileURL)
  }

  private func scheduleSave() {
    pendingSaveTask?.cancel()
    pendingSaveTask = Task { [clock, debounce, weak self] in
      do {
        try await clock.sleep(for: debounce, tolerance: nil)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.flushPending()
    }
  }

  private func flushPending() {
    do {
      try AtomicFileStore.write(inbox, to: fileURL)
    } catch {
      logger.error("Failed to save notifications.json: \(String(describing: error))")
    }
  }

  // MARK: - Unread signal

  /// Count of entries whose `isUnread` is true — the authoritative Dock-badge source (DEC-13).
  var unreadCount: Int {
    inbox.notifications.reduce(into: 0) { total, notification in
      if notification.isUnread { total += 1 }
    }
  }

  /// Emits the latest `unreadCount` on every mutation. The NotificationCoordinator
  /// (M4) subscribes to this to drive `DockBadger.setUnreadCount`.
  var unreadPublisher: AsyncStream<Int> { unreadStream }

  /// Fresh inbox-change stream — yields the current inbox on subscribe,
  /// then on every mutation. See field doc on `inboxSubscribers`.
  func observeInbox() -> AsyncStream<NotificationInbox> {
    AsyncStream { [self] continuation in
      let id = UUID()
      inboxSubscribers[id] = continuation
      continuation.yield(inbox)
      continuation.onTermination = { [weak self, id] _ in
        Task { @MainActor [weak self] in
          self?.inboxSubscribers.removeValue(forKey: id)
        }
      }
    }
  }

  private func publishMutation() {
    unreadContinuation.yield(unreadCount)
    let snapshot = inbox
    for (_, continuation) in inboxSubscribers {
      continuation.yield(snapshot)
    }
  }

  // MARK: - Sweep

  private static func applySweep(_ inbox: NotificationInbox, now: Date) -> NotificationInbox {
    var swept = inbox
    swept.notifications.removeAll { notification in
      guard let dismissedAt = notification.dismissedAt else { return false }
      return now.timeIntervalSince(dismissedAt) > softDeleteWindow
    }
    if swept.notifications.count > retentionCap {
      swept.notifications.removeLast(swept.notifications.count - retentionCap)
    }
    return swept
  }

  private func backupBrokenFile() {
    BrokenFileBackup.moveAside(at: fileURL, logger: logger)
  }
}
