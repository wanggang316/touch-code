import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Behavioural tests for `NotificationCoordinator` (M2.T2). Each test
/// declares the AC ID it covers; the runtime probe at the milestone gate
/// is the authoritative check, but these tests pin the production code
/// path so a future refactor cannot silently regress the chokepoint.
@MainActor
struct NotificationCoordinatorTests {
  // MARK: - Test fixtures

  private func makeInbox() -> (NotificationStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "notif-coordinator-\(UUID().uuidString).json"
    )
    return (NotificationStore(fileURL: url), url)
  }

  private func makeCandidate(sourceIsFocused: Bool = false) -> NotificationCoordinator.Candidate {
    let source = InboxEntry.SourcePath(
      projectID: ProjectID(),
      worktreeID: WorktreeID(),
      tabID: TabID(),
      paneID: PaneID()
    )
    let entry = InboxEntry(
      kind: .taskFinished,
      title: "fixture",
      body: "fixture-body",
      source: source
    )
    return .init(entry: entry, sourceIsFocused: sourceIsFocused)
  }

  private func makeCoordinator(
    inbox: NotificationStore,
    notifier: MockOSNotifier,
    reader: FakeNotificationSettingsReader
  ) -> NotificationCoordinator {
    NotificationCoordinator(
      inbox: inbox,
      osNotifier: notifier,
      settingsReader: reader,
      catalog: HierarchyClient.testValue,
      now: { Date() }
    )
  }

  // MARK: - Tests

  /// AC-V11-CP-001 (negative path): a candidate whose source matches the
  /// globally-focused pane is dropped before any sink fires — no inbox
  /// row, no banner, no badge update. The only `.dropped` reason the
  /// coordinator returns.
  @Test
  func focusedSourceDropsBeforeAnySink() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate(sourceIsFocused: true))

    #expect(decision == .dropped(reason: .sourceIsFocused))
    #expect(inbox.entries.isEmpty)
    #expect(notifier.posts.isEmpty)
  }

  /// AC-V11-CP-001: the coordinator reads settings at decision time, so a
  /// settings flip between two candidates takes effect on the second.
  @Test
  func evaluatesLiveSettingsAtDecisionTime() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    _ = await coordinator.handle(makeCandidate())
    #expect(inbox.entries.count == 1)

    reader.notifications.inAppEnabled = false
    _ = await coordinator.handle(makeCandidate())

    #expect(inbox.entries.count == 1)
  }

  /// AC-V11-CP-002: dropping a candidate must not retroactively surface
  /// when the toggle flips back on later. The dropped candidate is gone.
  @Test
  func droppedCandidateDoesNotResurfaceOnToggleFlip() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    _ = await coordinator.handle(makeCandidate())

    reader.notifications.inAppEnabled = false
    _ = await coordinator.handle(makeCandidate())
    #expect(inbox.entries.count == 1)

    reader.notifications.inAppEnabled = true
    // No new candidate fed — the previously dropped one stays dropped.
    #expect(inbox.entries.count == 1)
  }

  /// AC-V11-S-001: with the inbox off and system banners on, only the
  /// OS banner fires.
  @Test
  func inAppOffPostsBannerSkipsInbox() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    notifier.status = .authorized
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = false
    reader.notifications.systemEnabled = true
    reader.authStatus = .authorized
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate())

    #expect(notifier.posts.count == 1)
    #expect(inbox.entries.isEmpty)
    if case let .posted(inAppAppended, osBannerPosted, _, badgeUpdated, _) = decision {
      #expect(inAppAppended == false)
      #expect(osBannerPosted == true)
      #expect(badgeUpdated == false)
    } else {
      Issue.record("expected .posted, got \(decision)")
    }
  }

  /// AC-V11-S-002: with the inbox on and system banners off, only the
  /// inbox grows.
  @Test
  func systemOffAppendsInboxSkipsBanner() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.systemEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate())

    #expect(inbox.entries.count == 1)
    #expect(notifier.posts.isEmpty)
    if case let .posted(inAppAppended, osBannerPosted, _, _, _) = decision {
      #expect(inAppAppended == true)
      #expect(osBannerPosted == false)
    } else {
      Issue.record("expected .posted, got \(decision)")
    }
  }

  /// AC-V11-S-003: with sound off, the banner still posts but the
  /// `playSound` argument forwarded to `OSNotifier.post` is false.
  @Test
  func soundOffPostsWithoutSound() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    notifier.status = .authorized
    let reader = FakeNotificationSettingsReader()
    reader.notifications.systemEnabled = true
    reader.notifications.soundEnabled = false
    reader.authStatus = .authorized
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decision = await coordinator.handle(makeCandidate())

    #expect(notifier.posts.count == 1)
    #expect(notifier.posts.last?.playSound == false)
    if case let .posted(_, _, soundPlayed, _, _) = decision {
      #expect(soundPlayed == false)
    } else {
      Issue.record("expected .posted, got \(decision)")
    }
  }

  /// AC-V11-S-005: with the dock badge toggle off, `Decision.badgeUpdated`
  /// is false even though the inbox still grows. (Production reads the
  /// badge from the inbox via `recomputeDockBadge` calling
  /// `DockBadger.setBadge(badgeCount)`. We assert against the highest-
  /// fidelity observable on the public `Decision` surface to avoid
  /// injecting a fake badger.)
  @Test
  func dockBadgeOffReportsNoBadgeUpdate() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = true
    reader.notifications.dockBadgeEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    let decisionOff = await coordinator.handle(makeCandidate())

    if case let .posted(_, _, _, badgeUpdated, _) = decisionOff {
      #expect(badgeUpdated == false)
    } else {
      Issue.record("expected .posted, got \(decisionOff)")
    }

    // Sanity check the other branch: with the badge toggle on,
    // `badgeUpdated` flips to true.
    reader.notifications.dockBadgeEnabled = true
    let decisionOn = await coordinator.handle(makeCandidate())
    if case let .posted(_, _, _, badgeUpdated, _) = decisionOn {
      #expect(badgeUpdated == true)
    } else {
      Issue.record("expected .posted, got \(decisionOn)")
    }
  }

  /// AC-V11-L-001 (static expectation): coordinator emits a drop log line
  /// at `.debug` whenever a gate suppressed a surface. Tested via the
  /// internal `lastDropReasons` seam — the runtime probe at the milestone
  /// gate is the authoritative L-001 check; this test just guarantees the
  /// production code path that emits the log lines is exercised.
  @Test
  func logsDropReasonsOnSuppressedGates() async throws {
    let (inbox, url) = makeInbox()
    defer { try? FileManager.default.removeItem(at: url) }
    let notifier = MockOSNotifier()
    let reader = FakeNotificationSettingsReader()
    reader.notifications.inAppEnabled = false
    reader.notifications.systemEnabled = false
    let coordinator = makeCoordinator(inbox: inbox, notifier: notifier, reader: reader)

    _ = await coordinator.handle(makeCandidate())

    #expect(coordinator.lastDropReasons.contains(.inAppDisabled))
    #expect(coordinator.lastDropReasons.contains(.systemDisabled))
  }
}
