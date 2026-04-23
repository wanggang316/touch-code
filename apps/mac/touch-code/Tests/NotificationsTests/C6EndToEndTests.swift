import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

/// M7 — end-to-end integration tests covering the full C6 pipeline with
/// a **live C3 HookDispatcher** (from plan 0003 M2.1), not the narrower
/// slice M4c's C6AppBootstrapTests exercised. Each test drives an
/// envelope through the real dispatcher and observes the downstream
/// sinks (MockOSNotifier, MockDockBadger, live InboxStore).
///
/// Two routing paths are covered:
/// - **Lifecycle via `dispatcher.fire()`.** For `.paneExited` and
///   `.paneCrashed`, a sentinel-prefixed subscription for the same
///   event type is installed on the dispatcher so `fire()`'s matching
///   filter routes to C6's `DetectionRouter` via the sentinel prefix.
///   This is the path `dispatcher.attach(to:catalog:)` takes for every
///   live event, exercising EventMapper → fire → dispatch → internal
///   subscriber → router → tracker → coordinator → sinks.
/// - **Rule-driven via `router.handle(envelope:ruleID:)`.** For
///   `.paneOutputMatch` envelopes, the dispatcher's `handle(envelope:)`
///   protocol method cannot recover the rule id from the envelope alone
///   (C3 M2.1.1 will add a command sidechannel). Tests use the explicit
///   seam to cover the rule path full-stack.
@MainActor
struct C6EndToEndTests {
  // MARK: - Lifecycle via dispatcher.fire()

  @Test
  func paneCrashedFiresThroughDispatcherAndPostsCrashedNotification() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    // Sentinel sub for pane.crashed — routes dispatcher.fire → dispatch
    // → internalSubscribers[sentinel] → DetectionRouter.handle(envelope:).
    Self.installSentinelSub(for: .paneCrashed, on: harness.bootstrap.hookDispatcher)

    let envelope = Self.envelope(
      event: .paneCrashed,
      paneID: paneID,
      data: .paneCrashed(reason: "pty fault")
    )
    await harness.bootstrap.hookDispatcher.fire(envelope)

    await harness.mockNotifier.waitForPostCount(1)
    let posted = try #require(harness.mockNotifier.postedNotifications.first)
    #expect(posted.kind == .crashed)
    #expect(harness.bootstrap.inboxStore.inbox.notifications.count == 1)
  }

  @Test
  func paneExitedZeroFiresCompletedNotification() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    Self.installSentinelSub(for: .paneExited, on: harness.bootstrap.hookDispatcher)

    let envelope = Self.envelope(
      event: .paneExited,
      paneID: paneID,
      data: .paneExited(exitCode: 0)
    )
    await harness.bootstrap.hookDispatcher.fire(envelope)

    await harness.mockNotifier.waitForPostCount(1)
    let posted = try #require(harness.mockNotifier.postedNotifications.first)
    #expect(posted.kind == .completed)
  }

  @Test
  func paneExitedNonZeroFiresCrashedNotification() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    Self.installSentinelSub(for: .paneExited, on: harness.bootstrap.hookDispatcher)

    let envelope = Self.envelope(
      event: .paneExited,
      paneID: paneID,
      data: .paneExited(exitCode: 127)
    )
    await harness.bootstrap.hookDispatcher.fire(envelope)

    await harness.mockNotifier.waitForPostCount(1)
    #expect(harness.mockNotifier.postedNotifications.first?.kind == .crashed)
  }

  // MARK: - Rule-driven via router.handle(envelope:ruleID:)

  @Test
  func blockedOnInputRuleDrivesFullStack() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    let envelope = Self.outputMatchEnvelope(
      paneID: paneID,
      match: "Do you want to proceed?"
    )
    harness.bootstrap.router.handle(envelope: envelope, ruleID: "claude.blocked_on_input")

    await harness.mockNotifier.waitForPostCount(1)
    let posted = try #require(harness.mockNotifier.postedNotifications.first)
    #expect(posted.kind == .blockedOnInput)
    #expect(posted.agent == "claude")
  }

  // MARK: - Muting and permission

  @Test
  func mutedRuleStillInboxesButDoesNotPost() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    harness.bootstrap.settingsStore.mutateNotifications {
      $0.mute.mutedRuleIDs.insert("claude.blocked_on_input")
    }

    let envelope = Self.outputMatchEnvelope(paneID: paneID, match: "Do you want to proceed?")
    harness.bootstrap.router.handle(envelope: envelope, ruleID: "claude.blocked_on_input")

    // Inbox accrual is synchronous; wait briefly for the coordinator's
    // bind-loop tick. Since the post path is suppressed there's no
    // MockOSNotifier event to await on — we use the InboxStore
    // publisher instead.
    try await harness.waitForInboxCount(1)
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.bootstrap.inboxStore.inbox.notifications.count == 1)
  }

  @Test
  func deniedPermissionInboxesButSkipsOSPost() async throws {
    let harness = try await Self.startHarness(authStatus: .denied, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    let envelope = Self.outputMatchEnvelope(paneID: paneID, match: "Do you want to proceed?")
    harness.bootstrap.router.handle(envelope: envelope, ruleID: "claude.blocked_on_input")

    try await harness.waitForInboxCount(1)
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.bootstrap.inboxStore.inbox.notifications.count == 1)
  }

  // MARK: - attach(to:) event-stream smoke test

  @Test
  func attachedEventStreamRoutesPaneCrashedEndToEnd() async throws {
    let harness = try await Self.startHarness(authStatus: .authorized, agentPaneCount: 1)
    defer { harness.bootstrap.shutdown() }
    let paneID = try #require(harness.seedPaneIDs.first)

    Self.installSentinelSub(for: .paneCrashed, on: harness.bootstrap.hookDispatcher)

    var continuation: AsyncStream<TerminalEvent>.Continuation!
    let stream = AsyncStream<TerminalEvent> { c in continuation = c }
    let hierarchy = harness.bootstrap.registry.hierarchy
    harness.bootstrap.hookDispatcher.attach(to: stream, catalog: { hierarchy.catalog })

    // Yield a crash event — EventMapper produces a fully-anchored
    // envelope, fire() matches the sentinel sub, dispatch() hands the
    // envelope to DetectionRouter, which routes to the tracker +
    // coordinator + sinks.
    continuation.yield(.paneCrashed(paneID, reason: "segfault"))

    await harness.mockNotifier.waitForPostCount(1)
    #expect(harness.mockNotifier.postedNotifications.first?.kind == .crashed)

    continuation.finish()
  }

  // MARK: - Harness

  struct Harness {
    let bootstrap: C6AppBootstrap
    let mockNotifier: MockOSNotifier
    let mockBadger: MockDockBadger
    let mockDelegate: MockPermissionDelegate
    let tempDirectory: URL
    let seedPaneIDs: [PaneID]

    /// Inbox-mutation await. The coordinator's bind loop is async; for
    /// paths where OS posting is suppressed (muting, denial) we can't
    /// race on MockOSNotifier — instead we observe the inbox directly
    /// via `observeInbox()`, the same multi-subscriber primitive M5
    /// added.
    @MainActor
    func waitForInboxCount(_ target: Int) async throws {
      var iterator = bootstrap.inboxStore.observeInbox().makeAsyncIterator()
      while let next = await iterator.next() {
        if next.notifications.count >= target { return }
      }
    }
  }

  static func startHarness(
    authStatus: AuthorizationStatusCache,
    agentPaneCount: Int
  ) async throws -> Harness {
    let temp = FileManager.default.temporaryDirectory
      .appending(component: "c6-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

    let hookConfigURL = temp.appendingPathComponent("hooks.json")
    let hookStore = HookConfigStore(fileURL: hookConfigURL, debounceSeconds: 0)
    let dispatcher = HookDispatcher(
      config: .empty,
      store: hookStore,
      executor: FakeHookExecutor(),
      actionDispatcher: RecordingHookActionDispatcher()
    )

    // Seed catalog with N agent-labelled Panes so TrackerRegistry.bootstrap
    // creates trackers and step-10 sweep wires them into the coordinator.
    var seedPaneIDs: [PaneID] = []
    let catalogURL = temp.appendingPathComponent("catalog.json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let catalog = Self.makeCatalog(agentPaneCount: agentPaneCount, paneIDs: &seedPaneIDs)
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )

    let notifier = MockOSNotifier(initialStatus: authStatus.asAuthorizationStatus())
    let badger = MockDockBadger()
    let delegate = MockPermissionDelegate(decision: .continue)

    let settingsURL = temp.appendingPathComponent("settings.json")
    let inboxURL = temp.appendingPathComponent("notifications.json")
    let rulesURL = temp.appendingPathComponent("detection-rules.json")

    let settings = SettingsStore(fileURL: settingsURL, debounceWindow: .seconds(3600))
    settings.mutateNotifications { $0.authStatus = authStatus }
    try settings.saveNow()

    let bootstrap = try await C6AppBootstrap.start(
      hierarchy: hierarchy,
      hookDispatcher: dispatcher,
      hookConfigStore: hookStore,
      settingsStore: settings,
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
      tempDirectory: temp,
      seedPaneIDs: seedPaneIDs
    )
  }

  static func makeCatalog(agentPaneCount: Int, paneIDs: inout [PaneID]) -> Catalog {
    guard agentPaneCount > 0 else { return .default }
    let panes: [Pane] = (0..<agentPaneCount).map { _ in
      Pane(workingDirectory: "/tmp/agent", initialCommand: nil, labels: ["agent:claude"])
    }
    paneIDs = panes.map(\.id)
    let tab = Tab(splitTree: SplitTree(leaf: panes[0].id), panes: panes)
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id)
    let project = Project(
      name: "p", rootPath: "/p", gitRoot: "/p",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let space = Space(name: "s", projects: [project], selectedProjectID: project.id)
    return Catalog(
      version: Catalog.currentVersion,
      windows: [],
      spaces: [space],
      selectedSpaceID: space.id
    )
  }

  static func installSentinelSub(for event: HookEvent, on dispatcher: HookDispatcher) {
    let sub = HookSubscription(
      event: event,
      command: "\(RuleStore.sentinelPrefix)lifecycle-\(event.rawValue)"
    )
    var config = dispatcher.loadedConfig
    config.subscriptions.append(sub)
    dispatcher.setConfig(config)
  }

  static func envelope(
    event: HookEvent,
    paneID: PaneID,
    data: HookEventData
  ) -> HookEnvelope {
    HookEnvelope(
      version: HookEnvelope.currentVersion,
      event: event,
      timestamp: Date(),
      space: nil,
      project: nil,
      worktree: nil,
      tab: nil,
      pane: HookEnvelope.PaneRef(
        id: paneID,
        workingDirectory: "/tmp/agent",
        initialCommand: nil,
        labels: ["agent:claude"]
      ),
      data: data
    )
  }

  static func outputMatchEnvelope(paneID: PaneID, match: String) -> HookEnvelope {
    envelope(
      event: .paneOutputMatch,
      paneID: paneID,
      data: .paneOutputMatch(
        match: match,
        matchedRange: HookMatchRange(start: 0, length: match.count),
        output: Data(match.utf8),
        outputBytes: match.count
      )
    )
  }
}
