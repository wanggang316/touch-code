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
}

// MARK: - Live bridge

extension InboxClient {
  @MainActor
  static func live(inbox: InboxStore, settings: SettingsStore) -> InboxClient {
    InboxClient(
      dismiss: { ids in inbox.dismiss(ids) },
      markRead: { ids in inbox.markRead(ids) },
      clearAll: { inbox.clearAll() },
      muteRule: { ruleID in
        settings.mutate { $0.notifications.mute.mutedRuleIDs.insert(ruleID) }
      },
      observe: { inbox.observeInbox() },
      observeUnread: { inbox.unreadPublisher }
    )
  }
}

// MARK: - DependencyKey

extension InboxClient: DependencyKey {
  static let liveValue: InboxClient = InboxClient(
    dismiss: { _ in fatalError("InboxClient.liveValue not configured; wire via .withDependencies at app startup") },
    markRead: { _ in fatalError("InboxClient.liveValue not configured") },
    clearAll: { fatalError("InboxClient.liveValue not configured") },
    muteRule: { _ in fatalError("InboxClient.liveValue not configured") },
    observe: { AsyncStream { $0.finish() } },
    observeUnread: { AsyncStream { $0.finish() } }
  )

  static let testValue: InboxClient = InboxClient(
    dismiss: unimplemented("InboxClient.dismiss"),
    markRead: unimplemented("InboxClient.markRead"),
    clearAll: unimplemented("InboxClient.clearAll"),
    muteRule: unimplemented("InboxClient.muteRule"),
    observe: unimplemented(
      "InboxClient.observe",
      placeholder: AsyncStream { $0.finish() }
    ),
    observeUnread: unimplemented(
      "InboxClient.observeUnread",
      placeholder: AsyncStream { $0.finish() }
    )
  )
}
