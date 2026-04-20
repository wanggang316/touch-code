import Foundation
import TouchCodeCore

/// Owns the 11-step app-shell wiring for C6 (exec plan 0006 M4). Holds the
/// constructed services for the lifetime of the app (or the integration
/// test). Constructed once at app launch (or test harness) via
/// `C6AppBootstrap.start(...)` and torn down via `shutdown()`.
///
/// The wiring sequence (plan §M4 §Wire into TouchCodeApp.swift):
///   1. load NotificationSettingsStore
///   2. load InboxStore
///   3. load + materialise rules via RuleStore → C3 HookConfigStore
///   4. construct TrackerRegistry
///   5. registry.bootstrap() — creates trackers for pre-existing agent Panels
///   6. subscribeToHierarchyEvents() — deferred (plan R/M4c.1): HierarchyManager
///      does not yet expose an event stream; Panel add/remove while the session
///      is running requires an explicit call to `trackerRegistry.create/destroy`.
///   7. construct DetectionRouter
///   8. dispatcher.register(subscriber: router, for: sentinel prefix)
///   9. construct NotificationCoordinator
///  10. restart-time permission sweep: for tracker in registry.allTrackers
///      { await coordinator.onAgentPanelCreated(tracker.panelID) }
///  11. Task { await coordinator.bind(to: router.transitions) }
@MainActor
final class C6AppBootstrap {
  let settingsStore: NotificationSettingsStore
  let inboxStore: InboxStore
  let ruleStore: RuleStore
  let registry: TrackerRegistry
  let router: DetectionRouter
  let coordinator: NotificationCoordinator
  let hookDispatcher: HookDispatcher
  let rules: AgentDetectionRules

  private var bindTask: Task<Void, Never>?

  /// Build the full C6 stack from the supplied dependencies and run the
  /// 11-step wiring sequence. The caller is expected to retain the
  /// returned instance for the lifetime it wants notifications live.
  static func start(
    hierarchy: HierarchyManager,
    hookDispatcher: HookDispatcher,
    hookConfigStore: HookConfigStore,
    settingsURL: URL = ConfigPaths.configDirectory().appendingPathComponent("settings.json", isDirectory: false),
    inboxURL: URL = ConfigPaths.notificationInbox(),
    detectionRulesURL: URL = ConfigPaths.detectionRules(),
    osNotifier: any OSNotifier,
    badger: any DockBadger,
    permissionDelegate: any NotificationPermissionDelegate,
    clock: any Clock<Duration> = ContinuousClock()
  ) async throws -> C6AppBootstrap {
    // Step 1 — settings
    let settings = NotificationSettingsStore(fileURL: settingsURL, clock: clock)
    _ = try settings.load()

    // Step 2 — inbox
    let inbox = InboxStore(fileURL: inboxURL, clock: clock)
    _ = try inbox.load()

    // Ensure the defaults are present so step 3 always finds something to load.
    try DefaultRules.installIfMissing(at: detectionRulesURL)

    // Step 3 — rules materialised through C3's reserved-namespace API
    let adapter = HookConfigStoreAdapter(store: hookConfigStore)
    let ruleStore = RuleStore(fileURL: detectionRulesURL, hookWriter: adapter)
    let rules = try ruleStore.loadAndMaterialise()
    let renderer = try TemplateRenderer(rules: rules)

    // Step 4–5 — registry + bootstrap
    let registry = TrackerRegistry(
      hierarchy: hierarchy,
      idleThreshold: rules.idleThresholdSeconds,
      clock: clock
    )
    registry.bootstrap()
    // Step 6 — subscribeToHierarchyEvents is deferred until HierarchyManager
    // exposes an event stream; see class-level doc comment.

    // Step 7 — router
    let router = DetectionRouter(rules: rules, registry: registry, renderer: renderer)

    // Step 8 — register with C3 dispatcher
    try hookDispatcher.register(subscriber: router, for: RuleStore.sentinelPrefix)

    // Step 9 — coordinator
    let coordinator = NotificationCoordinator(
      inbox: inbox,
      badger: badger,
      osNotifier: osNotifier,
      settings: settings,
      registry: registry,
      permissionDelegate: permissionDelegate,
      ruleStore: ruleStore,
      router: router
    )

    let bootstrap = C6AppBootstrap(
      settingsStore: settings,
      inboxStore: inbox,
      ruleStore: ruleStore,
      registry: registry,
      router: router,
      coordinator: coordinator,
      hookDispatcher: hookDispatcher,
      rules: rules
    )

    // Step 10 — restart-time permission sweep
    for tracker in registry.allTrackers {
      await coordinator.onAgentPanelCreated(tracker.panelID)
    }

    // Step 11 — bind router → coordinator for the app lifetime. The task
    // captures `router` + `coordinator` by value (reference types); this
    // keeps the stream alive even if `bootstrap` is later referenced only
    // weakly from elsewhere. Task cancellation on `shutdown()` tears the
    // loop down cleanly.
    bootstrap.bindTask = Task { [router, coordinator] in
      await coordinator.bind(to: router.transitions)
    }

    return bootstrap
  }

  init(
    settingsStore: NotificationSettingsStore,
    inboxStore: InboxStore,
    ruleStore: RuleStore,
    registry: TrackerRegistry,
    router: DetectionRouter,
    coordinator: NotificationCoordinator,
    hookDispatcher: HookDispatcher,
    rules: AgentDetectionRules
  ) {
    self.settingsStore = settingsStore
    self.inboxStore = inboxStore
    self.ruleStore = ruleStore
    self.registry = registry
    self.router = router
    self.coordinator = coordinator
    self.hookDispatcher = hookDispatcher
    self.rules = rules
  }

  deinit {
    // Last-resort cleanup if the app shell forgot to call `shutdown()`.
    // The bindTask is MainActor-isolated; we cannot touch it from a
    // nonisolated deinit in Swift 6. Callers must invoke `shutdown()`
    // explicitly before drop-out. If they don't, the bind task stays
    // alive consuming the router stream until process exit — the
    // dispatcher registration also lingers. Documented as the only
    // supported teardown path; callers that violate this will see a
    // leaked Task in Instruments.
  }

  /// Explicit teardown. The **only documented path** to release the
  /// bootstrap's hold on C3's dispatcher. Call from the app shell before
  /// the bootstrap goes out of scope (e.g. `applicationWillTerminate`).
  /// Idempotent — safe to call more than once.
  func shutdown() {
    bindTask?.cancel()
    bindTask = nil
    hookDispatcher.unregister(prefix: RuleStore.sentinelPrefix)
  }

  /// Synchronous flush for app termination (`applicationWillTerminate`).
  func flushPendingWrites() throws {
    try inboxStore.saveNow()
    try settingsStore.saveNow()
  }
}
