import Foundation
import Testing

@testable import touch_code
import TouchCodeCore

@MainActor
struct NotificationCoordinatorTests {
  // MARK: - Muting policy

  @Test
  func authorizedUnmutedRuleAppendsInboxAndPostsOS() async throws {
    let harness = Self.make(authStatus: .authorized)
    await harness.feed(.init(
      transition: Self.transition(to: .blockedOnInput, trigger: .rule(id: "claude.blocked")),
      agent: "claude",
      title: "Claude waits",
      body: "prompt",
      kind: .blockedOnInput
    ))
    #expect(harness.mockNotifier.postedNotifications.count == 1)
    #expect(harness.inbox.inbox.notifications.count == 1)
  }

  @Test
  func deniedStatusSkipsOSPostButStillInboxes() async throws {
    let harness = Self.make(authStatus: .denied)
    await harness.feed(.init(
      transition: Self.transition(to: .completed, trigger: .rule(id: "rule")),
      agent: "claude",
      title: "done",
      body: "",
      kind: .completed
    ))
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.inbox.inbox.notifications.count == 1)
  }

  @Test
  func mutedRuleIDSkipsOSPostButStillInboxes() async throws {
    let harness = Self.make(authStatus: .authorized, mutedRuleIDs: ["rule.done"])
    await harness.feed(.init(
      transition: Self.transition(to: .completed, trigger: .rule(id: "rule.done")),
      agent: "claude",
      title: "done",
      body: "",
      kind: .completed
    ))
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.inbox.inbox.notifications.count == 1)
  }

  @Test
  func idleKindMutedByDefault() async throws {
    let harness = Self.make(authStatus: .authorized)
    await harness.feed(.init(
      transition: Self.transition(to: .idle, trigger: .idleTimer(seconds: 120)),
      agent: "claude",
      title: "idle",
      body: "",
      kind: .idle
    ))
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.inbox.inbox.notifications.count == 1)
  }

  @Test
  func idleSurfacedWhenSurfaceIdleTrue() async throws {
    let harness = Self.make(authStatus: .authorized, surfaceIdle: true)
    await harness.feed(.init(
      transition: Self.transition(to: .idle, trigger: .idleTimer(seconds: 120)),
      agent: "claude",
      title: "idle",
      body: "",
      kind: .idle
    ))
    #expect(harness.mockNotifier.postedNotifications.count == 1)
  }

  @Test
  func redactBodiesReplacesOSBodyButKeepsInboxOriginal() async throws {
    let harness = Self.make(authStatus: .authorized, redactBodies: true)
    await harness.feed(.init(
      transition: Self.transition(to: .completed, trigger: .rule(id: "x")),
      agent: "claude",
      title: "t",
      body: "Secret API key: foo",
      kind: .completed
    ))
    #expect(harness.mockNotifier.postedNotifications.first?.body == "(redacted)")
    #expect(harness.inbox.inbox.notifications.first?.body == "Secret API key: foo")
  }

  @Test
  func mutedPanelIDSkipsOSPost() async throws {
    let panelID = PanelID()
    let harness = Self.make(authStatus: .authorized, mutedPanelIDs: [panelID])
    await harness.feed(.init(
      transition: AgentStateTransition(
        panelID: panelID,
        from: .running,
        to: .completed,
        at: Date(),
        trigger: .rule(id: "x")
      ),
      agent: "claude",
      title: "t",
      body: "b",
      kind: .completed
    ))
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.inbox.inbox.notifications.count == 1)
  }

  @Test
  func globalEnabledFalseDropsEverything() async throws {
    let harness = Self.make(authStatus: .authorized, globalEnabled: false)
    await harness.feed(.init(
      transition: Self.transition(to: .completed, trigger: .rule(id: "x")),
      agent: "claude",
      title: "t",
      body: "",
      kind: .completed
    ))
    #expect(harness.mockNotifier.postedNotifications.isEmpty)
    #expect(harness.inbox.inbox.notifications.isEmpty)
  }

  // MARK: - Permission prompt

  @Test
  func firstAgentPanelCreatedPromptsWhenNotDetermined() async throws {
    let harness = Self.make(authStatus: .notDetermined)
    let panelID = PanelID()
    await harness.coordinator.onAgentPanelCreated(panelID)
    #expect(harness.mockDelegate.presentPromptCalls == 1)
  }

  @Test
  func secondCallForSamePanelIsIdempotent() async throws {
    let harness = Self.make(authStatus: .notDetermined)
    let panelID = PanelID()
    await harness.coordinator.onAgentPanelCreated(panelID)
    await harness.coordinator.onAgentPanelCreated(panelID)
    #expect(harness.mockDelegate.presentPromptCalls == 1)
  }

  @Test
  func alreadyDeniedStatusDoesNotReprompt() async throws {
    let harness = Self.make(authStatus: .denied)
    let panelID = PanelID()
    await harness.coordinator.onAgentPanelCreated(panelID)
    #expect(harness.mockDelegate.presentPromptCalls == 0)
  }

  @Test
  func neverPromptFlagSuppressesDelegate() async throws {
    let harness = Self.make(authStatus: .notDetermined)
    harness.settings.mutate { $0.notifications.neverPrompt = true }
    await harness.coordinator.onAgentPanelCreated(PanelID())
    #expect(harness.mockDelegate.presentPromptCalls == 0)
  }

  @Test
  func continueDecisionTriggersOSRequest() async throws {
    let harness = Self.make(authStatus: .notDetermined, decision: .continue)
    harness.mockNotifier.nextRequestResult = .authorized
    await harness.coordinator.onAgentPanelCreated(PanelID())
    #expect(harness.mockNotifier.requestAuthorizationCalls == 1)
    #expect(harness.settings.settings.notifications.authStatus == .authorized)
  }

  @Test
  func notNowDecisionSetsCoolDownTimestamp() async throws {
    let harness = Self.make(authStatus: .notDetermined, decision: .notNow)
    let before = Date()
    await harness.coordinator.onAgentPanelCreated(PanelID())
    let notNowUntil = harness.settings.settings.notifications.notNowUntil
    #expect(notNowUntil != nil)
    if let notNowUntil {
      // Cool-down is ≈ 24h in the future.
      let delta = notNowUntil.timeIntervalSince(before)
      #expect(delta > 23 * 60 * 60)
      #expect(delta < 25 * 60 * 60)
    }
  }

  @Test
  func neverDecisionSetsNeverPrompt() async throws {
    let harness = Self.make(authStatus: .notDetermined, decision: .never)
    await harness.coordinator.onAgentPanelCreated(PanelID())
    #expect(harness.settings.settings.notifications.neverPrompt == true)
  }

  @Test
  func refreshAuthorizationStatusUpdatesSettingsCache() async throws {
    let harness = Self.make(authStatus: .notDetermined)
    harness.mockNotifier.currentStatus = .denied
    await harness.coordinator.refreshAuthorizationStatus()
    #expect(harness.settings.settings.notifications.authStatus == .denied)
  }

  // MARK: - Harness

  private static func make(
    authStatus: AuthorizationStatusCache = .authorized,
    mutedRuleIDs: Set<String> = [],
    mutedPanelIDs: Set<PanelID> = [],
    surfaceIdle: Bool = false,
    redactBodies: Bool = false,
    globalEnabled: Bool = true,
    decision: PermissionDecision = .continue
  ) -> Harness {
    let inbox = InboxStore(
      fileURL: FileManager.default.temporaryDirectory.appending(component: "\(UUID()).json"),
      debounce: .seconds(3600)
    )
    let badger = MockDockBadger()
    let notifier = MockOSNotifier(initialStatus: authStatus.asAuthorizationStatus())
    let delegate = MockPermissionDelegate(decision: decision)

    let settings = SettingsStore(
      fileURL: FileManager.default.temporaryDirectory.appending(component: "\(UUID()).json"),
      debounce: .seconds(3600)
    )
    settings.mutate {
      $0.notifications.authStatus = authStatus
      $0.notifications.mute.enabled = globalEnabled
      $0.notifications.mute.surfaceIdle = surfaceIdle
      $0.notifications.mute.redactBodies = redactBodies
      $0.notifications.mute.mutedRuleIDs = mutedRuleIDs
      $0.notifications.mute.mutedPanelIDs = mutedPanelIDs
    }

    let registry = TrackerRegistry(
      hierarchy: HierarchyManager(
        catalog: .default,
        store: CatalogStore(fileURL: FileManager.default.temporaryDirectory.appending(component: "\(UUID()).json")),
        runtime: FakeHierarchyRuntime()
      ),
      idleThreshold: 120
    )
    let coordinator = NotificationCoordinator(
      inbox: inbox,
      badger: badger,
      osNotifier: notifier,
      settings: settings,
      registry: registry,
      permissionDelegate: delegate
    )
    return Harness(
      inbox: inbox,
      badger: badger,
      mockNotifier: notifier,
      mockDelegate: delegate,
      settings: settings,
      coordinator: coordinator
    )
  }

  private static func transition(
    to: AgentState,
    trigger: AgentStateTransition.Trigger
  ) -> AgentStateTransition {
    AgentStateTransition(
      panelID: PanelID(),
      from: .running,
      to: to,
      at: Date(),
      trigger: trigger
    )
  }
}

// MARK: - Mocks

@MainActor
final class MockOSNotifier: OSNotifier {
  var currentStatus: AuthorizationStatus
  var nextRequestResult: AuthorizationStatus?
  private(set) var postedNotifications: [AgentNotification] = []
  private(set) var requestAuthorizationCalls = 0

  init(initialStatus: AuthorizationStatus) {
    self.currentStatus = initialStatus
  }

  // swiftlint:disable async_without_await
  func currentAuthorizationStatus() async -> AuthorizationStatus { currentStatus }
  func requestAuthorization() async -> AuthorizationStatus {
    requestAuthorizationCalls += 1
    if let next = nextRequestResult { currentStatus = next }
    return currentStatus
  }
  func post(_ notification: AgentNotification) async {
    postedNotifications.append(notification)
  }
  // swiftlint:enable async_without_await
}

@MainActor
final class MockDockBadger: DockBadger {
  private(set) var calls: [Int] = []
  func setUnreadCount(_ n: Int) { calls.append(n) }
}

@MainActor
final class MockPermissionDelegate: NotificationPermissionDelegate {
  let decision: PermissionDecision
  private(set) var presentPromptCalls = 0
  init(decision: PermissionDecision) { self.decision = decision }
  // swiftlint:disable:next async_without_await
  func presentPrompt() async -> PermissionDecision {
    presentPromptCalls += 1
    return decision
  }
}

// MARK: - Harness

@MainActor
struct Harness {
  let inbox: InboxStore
  let badger: MockDockBadger
  let mockNotifier: MockOSNotifier
  let mockDelegate: MockPermissionDelegate
  let settings: SettingsStore
  let coordinator: NotificationCoordinator

  /// Drive one RouterOutput through the coordinator. Uses the direct
  /// `handle(output:)` entry point — the `bind(to:)` path's unread-publisher
  /// loop never terminates while the inbox is alive, so keeping tests off
  /// `bind` avoids a deadlock in the harness.
  func feed(_ output: DetectionRouter.RouterOutput) async {
    await coordinator.handle(output: output)
  }
}

// MARK: - Status bridge

extension AuthorizationStatusCache {
  func asAuthorizationStatus() -> AuthorizationStatus {
    switch self {
    case .notDetermined: return .notDetermined
    case .authorized: return .authorized
    case .denied: return .denied
    case .provisional: return .provisional
    }
  }
}
