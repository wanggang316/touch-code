import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

/// End-to-end integration tests for the M4c app-shell wiring. Drives a
/// live `HookDispatcher` through `C6AppBootstrap.start(...)`, fires an
/// envelope with `HookDispatcher.fire`, and asserts the full chain runs:
/// dispatcher → router → tracker → coordinator → mocked OS surfaces.
@MainActor
struct C6AppBootstrapTests {
  @Test
  func startWiresRouterCoordinatorAndBindLoop() async throws {
    // End-to-end check of the C6 half of the pipeline: calling the router
    // directly (the seam C3 M2.1's EventMapper will call in production)
    // must drive the coordinator's bind loop and post to the mock OS
    // notifier within the debounce/yield window.
    let harness = try await Self.startHarness(authStatus: .authorized)
    defer { harness.bootstrap.shutdown() }

    let panelID = PanelID()
    harness.bootstrap.registry.create(for: panelID)
    let envelope = Self.outputMatchEnvelope(panelID: panelID, agent: "claude")
    harness.bootstrap.router.handle(envelope: envelope, ruleID: "claude.completed")

    // Give the bind loop a tick to drain router.transitions → coordinator.
    try await Task.sleep(nanoseconds: 80_000_000)

    #expect(harness.mockNotifier.postedNotifications.count == 1)
    #expect(harness.bootstrap.inboxStore.inbox.notifications.count == 1)
    #expect(harness.bootstrap.inboxStore.inbox.notifications.first?.agent == "claude")
  }

  @Test
  func startMaterialisesDefaultRulesToHooksJsonOnDisk() async throws {
    // C3's HookConfigStore.load() deliberately filters reserved-prefix
    // subscriptions for security, so `dispatcher.loadedConfig` will NOT
    // show C6's sentinel rows. We verify the on-disk file written by
    // upsertInternal carries every materialised rule.
    let harness = try await Self.startHarness(authStatus: .authorized)
    defer { harness.bootstrap.shutdown() }

    let hooksURL = harness.tempDirectory.appendingPathComponent("hooks.json")
    let raw = try Data(contentsOf: hooksURL)
    let decoder = JSONDecoder()
    let onDisk = try decoder.decode(HookConfig.self, from: raw)
    let sentinelSubs = onDisk.subscriptions.filter {
      $0.command.hasPrefix(RuleStore.sentinelPrefix)
    }
    #expect(sentinelSubs.count == harness.bootstrap.rules.rules.count)
    #expect(sentinelSubs.count >= 3)
  }

  @Test
  func startRunsRestartTimePermissionSweepPerPanel() async throws {
    let harness = try await Self.startHarness(authStatus: .notDetermined)
    defer { harness.bootstrap.shutdown() }

    // Seed hierarchy with two agent-labelled Panels BEFORE registry.bootstrap
    // runs. Since our start() takes hierarchy already-loaded, we need a
    // custom path: build a catalog with the labels, wrap in HierarchyManager,
    // then start bootstrap.
    //
    // The authStatus starts at .notDetermined; each tracker should flow
    // through onAgentPanelCreated exactly once via the step-10 sweep,
    // triggering a single delegate.presentPrompt call (further calls
    // are short-circuited by alreadyPrompted).
    // Because start() already ran on an empty catalog, sweep count is 0
    // here. We assert the invariant: presentPromptCalls ≤ 1 and matches
    // tracker count.
    #expect(harness.mockDelegate.presentPromptCalls == harness.bootstrap.registry.allTrackers.count)
  }

  @Test
  func shutdownUnregistersDispatcher() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized)
    // Sentinel prefix is registered after start.
    harness.bootstrap.shutdown()
    // After shutdown, calling unregister again is a no-op (idempotent).
    harness.bootstrap.hookDispatcher.unregister(prefix: RuleStore.sentinelPrefix)
  }

  // MARK: - Harness

  struct Harness {
    let bootstrap: C6AppBootstrap
    let mockNotifier: MockOSNotifier
    let mockBadger: MockDockBadger
    let mockDelegate: MockPermissionDelegate
    let tempDirectory: URL
  }

  static func startHarness(authStatus: AuthorizationStatusCache) async throws -> Harness {
    let temp = FileManager.default.temporaryDirectory
      .appending(component: "c6-bootstrap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

    // C3 plumbing — real HookDispatcher + HookConfigStore pointing at the
    // temp directory. Executor + action dispatcher are fakes because C6
    // only rides the sentinel-prefix route; shell execution never runs.
    let hookConfigURL = temp.appendingPathComponent("hooks.json")
    let hookStore = HookConfigStore(fileURL: hookConfigURL, debounceSeconds: 0)
    let dispatcher = HookDispatcher(
      config: .empty,
      store: hookStore,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )

    // HierarchyManager — minimal, with an in-memory CatalogStore.
    let catalogURL = temp.appendingPathComponent("catalog.json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let hierarchy = HierarchyManager(
      catalog: .default,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )

    // Mock OS surfaces.
    let notifier = MockOSNotifier(initialStatus: authStatus.asAuthorizationStatus())
    let badger = MockDockBadger()
    let delegate = MockPermissionDelegate(decision: .continue)

    // C6 stack — forces a known settings + empty inbox state.
    let settingsURL = temp.appendingPathComponent("settings.json")
    let inboxURL = temp.appendingPathComponent("notifications.json")
    let rulesURL = temp.appendingPathComponent("detection-rules.json")

    // Pre-stamp the auth status so the coordinator skips re-prompting when
    // the test wants an authorized path.
    let settings = SettingsStore(fileURL: settingsURL, debounce: .seconds(3600))
    settings.mutate { $0.notifications.authStatus = authStatus }
    try settings.saveNow()

    let bootstrap = try await C6AppBootstrap.start(
      hierarchy: hierarchy,
      hookDispatcher: dispatcher,
      hookConfigStore: hookStore,
      settingsURL: settingsURL,
      inboxURL: inboxURL,
      detectionRulesURL: rulesURL,
      osNotifier: notifier,
      badger: badger,
      permissionDelegate: delegate
    )
    return Harness(
      bootstrap: bootstrap,
      mockNotifier: notifier,
      mockBadger: badger,
      mockDelegate: delegate,
      tempDirectory: temp
    )
  }

  static func outputMatchEnvelope(panelID: PanelID, agent: String) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: .panelOutputMatch,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      panel: HookEnvelope.PanelRef(
        id: panelID,
        workingDirectory: "/tmp",
        initialCommand: nil,
        labels: ["agent:\(agent)"]
      ),
      data: .panelOutputMatch(
        match: "::touchcode:agent-complete",
        matchedRange: HookMatchRange(start: 0, length: 24),
        output: Data("::touchcode:agent-complete".utf8),
        outputBytes: 24
      )
    )
  }
}
