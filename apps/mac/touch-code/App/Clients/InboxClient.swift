import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency-injection bridge over `InboxStore` + `SettingsStore`.
/// C6 M5's `InboxFeature` depends on this struct's closures, not on the
/// stores directly — the `liveValue` binds each closure to concrete
/// store instances at app startup via `.withDependencies`.
///
/// Mirrors `HierarchyClient` / `TerminalClient` in shape: a Sendable
/// value type whose closures are `@MainActor @Sendable`, plus an
/// `AsyncStream`-returning read path (`observe`) that lets reducers
/// subscribe without importing the `@Observable` store surface.
nonisolated struct InboxClient: Sendable {
  /// Dismiss specific notifications (soft-delete; 7-day sweep removes later).
  var dismiss: @MainActor @Sendable (_ ids: [UUID]) -> Void

  /// Mark specific notifications as read.
  var markRead: @MainActor @Sendable (_ ids: [UUID]) -> Void

  /// Mark every notification whose pane resolves (through `catalog`) to the
  /// given Worktree as read. Thin bridge over
  /// `InboxStore.markRead(forWorktree:in:)`; consumed by the T2 Header bell
  /// popover row-tap.
  var markReadForWorktree:
    @MainActor @Sendable (
      _ worktreeID: WorktreeID, _ catalog: Catalog
    ) -> Void

  /// Mark every notification belonging to the given Pane as read. Used
  /// by `tc focus` and other "acknowledge unread on focus" paths
  /// (v2 D13 / B10). Bridges `InboxStore.markRead(forPane:)`.
  var markReadForPane: @MainActor @Sendable (_ paneID: PaneID) -> Void

  /// Dismiss every notification in the inbox.
  var clearAll: @MainActor @Sendable () -> Void

  /// Add a rule id to `MuteSettings.mutedRuleIDs`. Subsequent transitions
  /// from that rule still accrue in the inbox but are not posted to the
  /// OS. See design §Muting + DEC-13.
  var muteRule: @MainActor @Sendable (_ ruleID: String) -> Void

  /// Stream of inbox snapshots. Yields the current inbox on subscribe,
  /// then on every mutation. Each call returns a fresh stream registered
  /// as a separate subscriber on `InboxStore` — multiple consumers do
  /// not fight over a single continuation.
  var observe: @MainActor @Sendable () -> AsyncStream<NotificationInbox>

  /// Stream of unread counts. Sibling of `observe` — same mutation fans
  /// into both. `NotificationCoordinator` already consumes this via
  /// `InboxStore.unreadPublisher`; the client exposes it for views that
  /// only need the count.
  var observeUnread: @MainActor @Sendable () -> AsyncStream<Int>

  /// Stream of per-worktree unread maps (v2 D11 / B8). Drives both the
  /// worktree-promotion reducer (`moveNotifiedWorktreeToTop`) and the
  /// future status-bar bell from the same source of truth.
  var observeUnreadByWorktree: @MainActor @Sendable () -> AsyncStream<[WorktreeID: Int]>
}

// MARK: - Live bridge

extension InboxClient {
  @MainActor
  static func live(inbox: InboxStore, settings: SettingsStore) -> InboxClient {
    InboxClient(
      dismiss: { ids in inbox.dismiss(ids) },
      markRead: { ids in inbox.markRead(ids) },
      markReadForWorktree: { worktreeID, catalog in
        inbox.markRead(forWorktree: worktreeID, in: catalog)
      },
      markReadForPane: { paneID in inbox.markRead(forPane: paneID) },
      clearAll: { inbox.clearAll() },
      muteRule: { ruleID in
        settings.mutateNotifications { $0.mute.mutedRuleIDs.insert(ruleID) }
      },
      observe: { inbox.observeInbox() },
      observeUnread: { inbox.unreadPublisher },
      observeUnreadByWorktree: { inbox.observeUnreadByWorktree() }
    )
  }
}

// MARK: - DependencyKey

extension InboxClient: DependencyKey {
  /// No-op fallback used before `AppState.bringUp` overrides the dependency
  /// and by SwiftUI previews that render inbox surfaces without the full
  /// runtime. Unlike `HierarchyClient` / `TerminalClient` whose mutations
  /// must surface to the runtime to be meaningful, inbox writes are
  /// safe to silently drop: the UI simply shows no unread state.
  static let liveValue: InboxClient = InboxClient(
    dismiss: { _ in },
    markRead: { _ in },
    markReadForWorktree: { _, _ in },
    markReadForPane: { _ in },
    clearAll: {},
    muteRule: { _ in },
    observe: { AsyncStream { $0.finish() } },
    observeUnread: { AsyncStream { $0.finish() } },
    observeUnreadByWorktree: { AsyncStream { $0.finish() } }
  )

  static let testValue: InboxClient = InboxClient(
    dismiss: unimplemented("InboxClient.dismiss"),
    markRead: unimplemented("InboxClient.markRead"),
    markReadForWorktree: unimplemented("InboxClient.markReadForWorktree"),
    markReadForPane: unimplemented("InboxClient.markReadForPane"),
    clearAll: unimplemented("InboxClient.clearAll"),
    muteRule: unimplemented("InboxClient.muteRule"),
    observe: unimplemented(
      "InboxClient.observe",
      placeholder: AsyncStream { $0.finish() }
    ),
    observeUnread: unimplemented(
      "InboxClient.observeUnread",
      placeholder: AsyncStream { $0.finish() }
    ),
    observeUnreadByWorktree: unimplemented(
      "InboxClient.observeUnreadByWorktree",
      placeholder: AsyncStream { $0.finish() }
    )
  )
}
