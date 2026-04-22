import Foundation
import TouchCodeCore
import os.log

/// Fan-out hub between `DetectionRouter` (producer) and the three notification
/// sinks (inbox, Dock badge, OS banner). One instance lives for the app's
/// lifetime, constructed by the 11-step app-shell wiring sequence (plan
/// §M4 §Wire into TouchCodeApp.swift). Muting policy (design §Muting) is
/// evaluated here; Dock-badge count authority is read from
/// `InboxStore.unreadPublisher` on every mutation (DEC-13).
///
/// Permission flow (DEC-4):
/// - First-run prompt is deferred to the first `onAgentPanelCreated` call
///   and gated by `alreadyPrompted` + the `authStatus` surfaced through the
///   injected `NotificationSettingsReader`; writes flow via the paired
///   `NotificationsMutator` (see typealias below).
/// - `NotificationPermissionDelegate` chooses between `.continue` (go to
///   UN request), `.notNow` (24h cool-down), `.never` (permanent suppress).
/// - Restart-time sweep: M4's wiring step 10 iterates `registry.allTrackers`
///   and calls `onAgentPanelCreated` per Panel — idempotent, so a second
///   invocation within the same session is a no-op.
@MainActor
final class NotificationCoordinator {
  /// Closure the coordinator invokes to mutate the persisted `notifications` sub-tree. In
  /// production this routes through `SettingsStore.mutateNotifications`; tests inject a
  /// recorder closure. Keeping the reader surface (`NotificationSettingsReader`) separate
  /// from the write channel prevents accidental debounced-save triggers from observe paths.
  typealias NotificationsMutator = @MainActor @Sendable (_ transform: (inout NotificationsSettings) -> Void) -> Void

  private let inbox: InboxStore
  private let badger: any DockBadger
  private let osNotifier: any OSNotifier
  private let settingsReader: any NotificationSettingsReader
  private let mutateSettings: NotificationsMutator
  private let registry: TrackerRegistry
  private let permissionDelegate: any NotificationPermissionDelegate
  private weak var ruleStore: RuleStore?
  private weak var router: DetectionRouter?
  private let logger = Logger(subsystem: "com.touch-code.notifications", category: "coordinator")

  /// Panels we have already walked through the permission-prompt branch
  /// in the current session. Guards against double-prompting when
  /// restart-time sweep and live creation fire for the same PanelID.
  private var alreadyPrompted: Set<PanelID> = []

  init(
    inbox: InboxStore,
    badger: any DockBadger,
    osNotifier: any OSNotifier,
    settingsReader: any NotificationSettingsReader,
    mutateSettings: @escaping NotificationsMutator,
    registry: TrackerRegistry,
    permissionDelegate: any NotificationPermissionDelegate,
    ruleStore: RuleStore? = nil,
    router: DetectionRouter? = nil
  ) {
    self.inbox = inbox
    self.badger = badger
    self.osNotifier = osNotifier
    self.settingsReader = settingsReader
    self.mutateSettings = mutateSettings
    self.registry = registry
    self.permissionDelegate = permissionDelegate
    self.ruleStore = ruleStore
    self.router = router
  }

  /// Wire the rule-reload dependencies after construction. `C6AppBootstrap`
  /// creates the coordinator in step 9 and the router+ruleStore are
  /// already available by then — this setter lets the bootstrap inject
  /// them without coordinating a five-argument init across every test.
  func attach(ruleStore: RuleStore, router: DetectionRouter) {
    self.ruleStore = ruleStore
    self.router = router
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
      handleUnread(count)
    }
  }

  /// Test entry point. Production prefers `bind(to:)`'s
  /// `consumeUnreadPublisher` loop; this shim lets tests drive one
  /// badge-update tick without starting the never-terminating inbox
  /// stream. Internal on purpose — not a public API.
  ///
  /// The Dock badge reflects unread only when both the dedicated Dock-badge
  /// toggle AND in-app notifications are enabled. Disabling either forces the
  /// badge to zero on the next tick — keeping the UI consistent with the
  /// NotificationsSettingsView caption that says in-app also gates the badge.
  func handleUnread(_ count: Int) {
    let shouldShow = settingsReader.dockBadgeEnabled && settingsReader.inAppEnabled
    badger.setUnreadCount(shouldShow ? count : 0)
  }

  // MARK: - Per-transition fan-out

  /// Process a single router output — inboxes, posts, badges. Exposed so
  /// tests can drive one-shot fan-out without starting the `bind()` loop
  /// (whose `unreadPublisher` consumer never terminates while the inbox
  /// is live).
  func handle(output: DetectionRouter.RouterOutput) async {
    guard settingsReader.mute.enabled else {
      logger.debug("Global notifications disabled; dropping output.")
      return
    }
    let muting = settingsReader.mute

    let body: String = output.body
    let notification = AgentNotification(
      panelID: output.transition.panelID,
      agent: output.agent,
      kind: output.kind,
      title: output.title,
      body: body
    )
    if settingsReader.inAppEnabled {
      inbox.append(notification)
    } else {
      logger.debug("In-app notifications disabled; skipping inbox append.")
    }

    guard settingsReader.systemEnabled else {
      logger.debug("System notifications disabled; skipping OS post.")
      return
    }
    guard
      shouldPostToOS(
        kind: output.kind, ruleID: Self.ruleID(from: output.transition.trigger), panelID: output.transition.panelID,
        muting: muting)
    else {
      return
    }
    guard settingsReader.authStatus.isAuthorized else {
      return
    }
    // Apply body redaction at the OS boundary only; inbox keeps the raw body.
    let posted: AgentNotification =
      muting.redactBodies
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
    await osNotifier.post(posted, playSound: settingsReader.soundEnabled)
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
    let status = settingsReader.authStatus
    guard status == .notDetermined else { return }
    if settingsReader.neverPrompt { return }
    if let until = settingsReader.notNowUntil, Date() < until { return }

    let decision = await permissionDelegate.presentPrompt()

    // TOCTOU close-out: `refreshAuthorizationStatus` may flip the cache to
    // `.authorized` while we were awaiting the sheet. Re-read here so a
    // user who grants permission in System Settings mid-prompt does not
    // face a redundant `requestAuthorization` call.
    if settingsReader.authStatus != .notDetermined {
      alreadyPrompted.insert(panelID)
      return
    }

    alreadyPrompted.insert(panelID)
    switch decision {
    case .continue:
      let newStatus = await osNotifier.requestAuthorization()
      mutateSettings { $0.authStatus = Self.cache(from: newStatus) }
    case .notNow:
      let cooldown = Date().addingTimeInterval(24 * 60 * 60)
      mutateSettings { $0.notNowUntil = cooldown }
    case .never:
      mutateSettings { $0.neverPrompt = true }
    }
  }

  /// Refresh the cached auth status from the OS. Call on
  /// `applicationDidBecomeActive` (R2 mitigation) — never prompts, only
  /// updates the cache.
  func refreshAuthorizationStatus() async {
    let status = await osNotifier.currentAuthorizationStatus()
    mutateSettings { $0.authStatus = Self.cache(from: status) }
  }

  // MARK: - Rule reload

  /// App-internal entry for the design-doc `reloadRules` verb (DEC-P4).
  /// Re-reads `detection-rules.json`, re-materialises the sentinel
  /// subscriptions into `hooks.json` via `RuleStore.reloadAndRematerialise`,
  /// and swaps the router's in-memory rule table. In-flight transitions
  /// keep their captured rule; post-swap envelopes resolve against the
  /// new set.
  ///
  /// Requires `ruleStore` + `router` dependencies (injected via init or
  /// `attach(ruleStore:router:)`). When either is missing — e.g. in
  /// lightweight unit-test harnesses — the call logs and returns without
  /// error.
  ///
  /// The `tc notifications rules reload` CLI verb (DEC-P4) will wire
  /// into this method once plan 0003's CLI follow-up lands.
  func reloadRules() throws {
    guard let ruleStore, let router else {
      // Programmer error — the bootstrap always injects these; seeing this
      // message means a caller constructed a coordinator without the
      // reload capability, then tried to reload. Debug builds trap
      // loudly so the wiring bug is caught; release builds degrade to a
      // safe no-op with an .error log so a shipped app doesn't crash.
      assertionFailure(
        "NotificationCoordinator.reloadRules called without ruleStore/router dependencies. "
          + "Bootstrap must inject both via init or attach(ruleStore:router:)."
      )
      logger.error("reloadRules called without ruleStore/router dependencies; no-op.")
      return
    }
    let newRules = try ruleStore.reloadAndRematerialise()
    let newRenderer = try TemplateRenderer(rules: newRules)
    router.setRules(newRules, renderer: newRenderer)
    logger.info("Reloaded \(newRules.rules.count) detection rule(s).")
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
