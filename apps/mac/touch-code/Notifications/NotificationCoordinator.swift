import Foundation
import os.log
import TouchCodeCore

/// Fan-out hub between `DetectionRouter` (producer) and the three notification
/// sinks (inbox, Dock badge, OS banner). One instance lives for the app's
/// lifetime, constructed by the 11-step app-shell wiring sequence (plan
/// §M4 §Wire into TouchCodeApp.swift). Muting policy (design §Muting) is
/// evaluated here; Dock-badge count authority is read from
/// `InboxStore.unreadPublisher` on every mutation (DEC-13).
///
/// Permission flow (DEC-4):
/// - First-run prompt is deferred to the first `onAgentPanelCreated` call
///   and gated by `alreadyPrompted` + the cached `authStatus` in
///   `SettingsStore`.
/// - `NotificationPermissionDelegate` chooses between `.continue` (go to
///   UN request), `.notNow` (24h cool-down), `.never` (permanent suppress).
/// - Restart-time sweep: M4's wiring step 10 iterates `registry.allTrackers`
///   and calls `onAgentPanelCreated` per Panel — idempotent, so a second
///   invocation within the same session is a no-op.
@MainActor
final class NotificationCoordinator {
  private let inbox: InboxStore
  private let badger: any DockBadger
  private let osNotifier: any OSNotifier
  private let settings: SettingsStore
  private let registry: TrackerRegistry
  private let permissionDelegate: any NotificationPermissionDelegate
  private let logger = Logger(subsystem: "com.touch-code.notifications", category: "coordinator")

  /// Panels we have already walked through the permission-prompt branch
  /// in the current session. Guards against double-prompting when
  /// restart-time sweep and live creation fire for the same PanelID.
  private var alreadyPrompted: Set<PanelID> = []

  init(
    inbox: InboxStore,
    badger: any DockBadger,
    osNotifier: any OSNotifier,
    settings: SettingsStore,
    registry: TrackerRegistry,
    permissionDelegate: any NotificationPermissionDelegate
  ) {
    self.inbox = inbox
    self.badger = badger
    self.osNotifier = osNotifier
    self.settings = settings
    self.registry = registry
    self.permissionDelegate = permissionDelegate
  }

  // MARK: - Binding

  /// Subscribe to the router's output stream + the inbox unread publisher.
  /// Spawns two concurrent loops under `async let`; returns once either
  /// stream finishes (normally never, for the app's lifetime).
  func bind(to outputs: AsyncStream<DetectionRouter.RouterOutput>) async {
    async let outputLoop: Void = consumeRouterOutputs(outputs)
    async let unreadLoop: Void = consumeUnreadPublisher()
    _ = await (outputLoop, unreadLoop)
  }

  private func consumeRouterOutputs(_ stream: AsyncStream<DetectionRouter.RouterOutput>) async {
    for await output in stream {
      await handle(output: output)
    }
  }

  private func consumeUnreadPublisher() async {
    for await count in inbox.unreadPublisher {
      if settings.settings.notifications.mute.badgeEnabled {
        badger.setUnreadCount(count)
      } else {
        badger.setUnreadCount(0)
      }
    }
  }

  // MARK: - Per-transition fan-out

  /// Process a single router output — inboxes, posts, badges. Exposed so
  /// tests can drive one-shot fan-out without starting the `bind()` loop
  /// (whose `unreadPublisher` consumer never terminates while the inbox
  /// is live).
  func handle(output: DetectionRouter.RouterOutput) async {
    guard settings.settings.notifications.mute.enabled else {
      logger.debug("Global notifications disabled; dropping output.")
      return
    }
    let muting = settings.settings.notifications.mute

    let body: String = output.body
    let notification = AgentNotification(
      panelID: output.transition.panelID,
      agent: output.agent,
      kind: output.kind,
      title: output.title,
      body: body
    )
    inbox.append(notification)

    guard shouldPostToOS(kind: output.kind, ruleID: Self.ruleID(from: output.transition.trigger), panelID: output.transition.panelID, muting: muting) else {
      return
    }
    guard settings.settings.notifications.authStatus.isAuthorized else {
      return
    }
    // Apply body redaction at the OS boundary only; inbox keeps the raw body.
    let posted: AgentNotification = muting.redactBodies
      ? AgentNotification(
          id: notification.id,
          panelID: notification.panelID,
          agent: notification.agent,
          kind: notification.kind,
          title: notification.title,
          body: "(redacted)",
          createdAt: notification.createdAt
        )
      : notification
    await osNotifier.post(posted)
  }

  private func shouldPostToOS(
    kind: AgentNotification.Kind,
    ruleID: String?,
    panelID: PanelID,
    muting: MuteSettings
  ) -> Bool {
    if let ruleID, muting.mutedRuleIDs.contains(ruleID) { return false }
    if muting.mutedPanelIDs.contains(panelID) { return false }
    if kind == .idle, !muting.surfaceIdle { return false }
    return true
  }

  private static func ruleID(from trigger: AgentStateTransition.Trigger) -> String? {
    if case .rule(let id) = trigger { return id }
    return nil
  }

  // MARK: - Permission

  /// Called once per tracker creation (by the app shell's step-10 sweep
  /// and by the registry's `trackerCreations` subscriber). First call
  /// after install on a `.notDetermined` status triggers the pre-prompt
  /// sheet via the delegate; subsequent calls are no-ops (idempotent).
  func onAgentPanelCreated(_ panelID: PanelID) async {
    if alreadyPrompted.contains(panelID) { return }
    alreadyPrompted.insert(panelID)
    let status = settings.settings.notifications.authStatus
    guard status == .notDetermined else { return }
    if settings.settings.notifications.neverPrompt { return }
    if let until = settings.settings.notifications.notNowUntil, Date() < until { return }

    let decision = await permissionDelegate.presentPrompt()
    switch decision {
    case .continue:
      let newStatus = await osNotifier.requestAuthorization()
      settings.mutate { $0.notifications.authStatus = Self.cache(from: newStatus) }
    case .notNow:
      let cooldown = Date().addingTimeInterval(24 * 60 * 60)
      settings.mutate { $0.notifications.notNowUntil = cooldown }
    case .never:
      settings.mutate { $0.notifications.neverPrompt = true }
    }
  }

  /// Refresh the cached auth status from the OS. Call on
  /// `applicationDidBecomeActive` (R2 mitigation) — never prompts, only
  /// updates the cache.
  func refreshAuthorizationStatus() async {
    let status = await osNotifier.currentAuthorizationStatus()
    settings.mutate { $0.notifications.authStatus = Self.cache(from: status) }
  }

  private static func cache(from status: AuthorizationStatus) -> AuthorizationStatusCache {
    switch status {
    case .notDetermined: return .notDetermined
    case .authorized: return .authorized
    case .denied: return .denied
    case .provisional: return .provisional
    }
  }
}

extension AuthorizationStatusCache {
  var isAuthorized: Bool {
    switch self {
    case .authorized, .provisional: return true
    case .notDetermined, .denied: return false
    }
  }
}
