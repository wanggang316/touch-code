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

    // Deterministic wait — MockOSNotifier.post resumes the waiter as
    // soon as the post count is satisfied. No wall-clock fence.
    await harness.mockNotifier.waitForPostCount(1)

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
    // Seed the catalog with two agent-labelled Panels BEFORE start() runs.
    // Step 5 (registry.bootstrap) will create two trackers; step 10 (sweep)
    // iterates them and calls onAgentPanelCreated exactly once each. With
    // `.notDetermined` auth status, each call presents the prompt.
    let harness = try await Self.startHarness(
      authStatus: .notDetermined,
      agentPanelCount: 2
    )
    defer { harness.bootstrap.shutdown() }

    #expect(harness.bootstrap.registry.allTrackers.count == 2)
    #expect(harness.mockDelegate.presentPromptCalls == 2)
  }

  @Test
  func reloadRulesSwapsRouterTableAndRematerialisesHooksJson() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized)
    defer { harness.bootstrap.shutdown() }

    // Hand-edit detection-rules.json with a single minimal rule; the
    // reload path should pick it up and the router's table should drop
    // every previous default rule.
    let rulesURL = harness.tempDirectory.appendingPathComponent("detection-rules.json")
    let newRules = AgentDetectionRules(
      idleThresholdSeconds: 60,
      rules: [
        AgentDetectionRules.Rule(
          id: "custom.done",
          agent: "custom",
          appliesWhen: .init(panelLabelledAgent: "custom", hookEvent: .panelOutputMatch),
          match: .containsAny(["done"]),
          transitionTo: .completed,
          title: "Custom finished",
          body: "ok"
        ),
      ]
    )
    try AtomicFileStore.write(newRules, to: rulesURL)

    try harness.bootstrap.coordinator.reloadRules()

    // Drive the router with an envelope referencing the old rule id.
    // The router's in-memory rule table no longer has this id, so the
    // envelope is counted as dropped synchronously — no sleep fence
    // needed to "prove absence" via a non-event.
    let panelID = PanelID()
    harness.bootstrap.registry.create(for: panelID)
    let droppedBefore = harness.bootstrap.router.droppedEnvelopesCount
    let stalePrevious = Self.outputMatchEnvelope(panelID: panelID, agent: "claude")
    harness.bootstrap.router.handle(envelope: stalePrevious, ruleID: "claude.completed")
    #expect(harness.bootstrap.router.droppedEnvelopesCount == droppedBefore + 1)
    #expect(harness.mockNotifier.postedNotifications.isEmpty)

    // The new rule should fire as expected. waitForPostCount replaces
    // the wall-clock sleep fence — MockOSNotifier.post resumes the
    // waiter the instant the count is satisfied, so there's no flake
    // window under CI load.
    let newEnvelope = Self.outputMatchEnvelope(panelID: panelID, agent: "custom")
    harness.bootstrap.router.handle(envelope: newEnvelope, ruleID: "custom.done")
    await harness.mockNotifier.waitForPostCount(1)
    #expect(harness.mockNotifier.postedNotifications.count == 1)
    #expect(harness.mockNotifier.postedNotifications.first?.title == "Custom finished")

    // hooks.json must have been rematerialised — exactly one sentinel sub,
    // with the new rule id.
    let hooksURL = harness.tempDirectory.appendingPathComponent("hooks.json")
    let onDisk = try JSONDecoder().decode(HookConfig.self, from: Data(contentsOf: hooksURL))
    let sentinelSubs = onDisk.subscriptions.filter { $0.command.hasPrefix(RuleStore.sentinelPrefix) }
    #expect(sentinelSubs.count == 1)
    #expect(sentinelSubs.first?.command == "\(RuleStore.sentinelPrefix)custom.done")
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

  static func startHarness(
    authStatus: AuthorizationStatusCache,
    agentPanelCount: Int = 0
  ) async throws -> Harness {
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

    // HierarchyManager — pre-seeded catalog when the test wants
    // agent-labelled Panels for the step-10 permission sweep to observe.
    let catalogURL = temp.appendingPathComponent("catalog.json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let initialCatalog = Self.makeCatalog(agentPanelCount: agentPanelCount)
    let hierarchy = HierarchyManager(
      catalog: initialCatalog,
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

  static func makeCatalog(agentPanelCount: Int) -> Catalog {
    guard agentPanelCount > 0 else { return .default }
    let panels: [Panel] = (0..<agentPanelCount).map { i in
      Panel(
        workingDirectory: "/tmp/agent-\(i)",
        initialCommand: nil,
        labels: ["agent:claude"]
      )
    }
    let tab = Tab(splitTree: SplitTree(leaf: panels[0].id), panels: panels)
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id)
    let project = Project(
      name: "p",
      rootPath: "/p",
      gitRoot: "/p",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id
    )
    let space = Space(name: "s", projects: [project], selectedProjectID: project.id)
    return Catalog(
      version: Catalog.currentVersion,
      windows: [],
      spaces: [space],
      selectedSpaceID: space.id
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
