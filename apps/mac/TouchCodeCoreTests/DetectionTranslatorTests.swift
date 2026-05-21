import Foundation
import Testing

@testable import TouchCodeCore

struct DetectionTranslatorTests {
  // MARK: - paneOutput

  @Test
  func paneOutputMarksProducedAndProducesNoEntry() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneOutput(pane, Data()),
      hasProducedOutput: []
    )
    #expect(step.entry == nil)
    #expect(step.outputFlag == .markProduced(pane))
  }

  // MARK: - desktopNotification (OSC 9)

  @Test
  func desktopNotificationWithoutPromptCueIsTaskFinished() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneInfoChanged(pane, .desktopNotification(title: "Build done", body: "5 targets compiled")),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.title == "Build done")
    #expect(step.entry?.paneID == pane)
  }

  @Test
  func desktopNotificationWithPermissionCueIsWaitingForInput() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Permission required", body: "")),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .waitingForInput)
  }

  @Test
  func desktopNotificationWithTitleSuffixedQuestionMarkIsWaitingForInput() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Apply migration?", body: "")),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .waitingForInput)
  }

  @Test
  func desktopNotificationWithQuestionMarkOnlyInBodyIsTaskFinished() {
    // "Add tests?" is rhetorical informational text in a build summary,
    // not a prompt. The classifier scopes the `?` cue to the title
    // suffix to avoid misclassifying these as waiting-for-input.
    let step = DetectionTranslator.translate(
      .paneInfoChanged(
        PaneID(),
        .desktopNotification(title: "Build done", body: "5 targets in 2.3s. Add tests?")
      ),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .taskFinished)
  }

  @Test
  func desktopNotificationWithApprovalCueIsWaitingForInput() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Approval needed", body: "rm /tmp/x")),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .waitingForInput)
  }

  @Test
  func classifyIsCaseInsensitive() {
    #expect(DetectionTranslator.classify(title: "PERMISSION", body: "") == .waitingForInput)
    #expect(DetectionTranslator.classify(title: "Done", body: "no cue here") == .taskFinished)
  }

  // MARK: - bellRang

  @Test
  func bellRangIsWaitingForInput() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneInfoChanged(pane, .bellRang),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .waitingForInput)
    #expect(step.entry?.paneID == pane)
    #expect(step.outputFlag == .unchanged)
  }

  // MARK: - commandFinished

  /// Convenience: 30 s in nanoseconds, comfortably above the default 10 s
  /// threshold so success / failure cases fire without suppression.
  private static let longDurationNs: UInt64 = 30 * 1_000_000_000

  @Test
  func commandFinishedZeroExitIsTaskFinished() {
    // Default threshold is 10 s; pass 30 s so the event fires.
    let step = DetectionTranslator.translate(
      .paneInfoChanged(
        PaneID(),
        .commandFinished(exitCode: 0, duration: Self.longDurationNs)
      ),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.title == "Command finished")
    #expect(step.drop == nil)
  }

  @Test
  func commandFinishedNonZeroExitMentionsStatus() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(
        PaneID(),
        .commandFinished(exitCode: 137, duration: Self.longDurationNs)
      ),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.title.contains("failed") == true)
    #expect(step.entry?.title.contains("exit 137") == true)
  }

  // MARK: - commandFinished suppression rules (M4.T1)

  @Test
  func commandFinishedDisabled_suppressesEvenLongSuccess() {
    let pane = PaneID()
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedEnabled: false,
      commandFinishedThresholdSec: 10
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.entry == nil)
    #expect(step.drop == .commandFinishedDisabled)
  }

  @Test
  func commandFinishedShort_suppressesBelowThreshold() {
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    // 5 s < 10 s threshold.
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 5 * 1_000_000_000)),
      context: context
    )
    #expect(step.entry == nil)
    #expect(step.drop == .commandFinishedShort)
  }

  @Test
  func commandFinishedExactlyAtThreshold_fires() {
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 10 * 1_000_000_000)),
      context: context
    )
    #expect(step.entry != nil)
    #expect(step.drop == nil)
    #expect(step.entry?.title == "Command finished")
  }

  @Test
  func commandFinishedLongSuccess_fires() {
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.entry?.title == "Command finished")
    #expect(step.drop == nil)
  }

  @Test
  func commandCancelledSIGINT_suppressed() {
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 130, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.entry == nil)
    #expect(step.drop == .commandCancelled)
  }

  @Test
  func commandCancelledSIGTERM_suppressed() {
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 143, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.entry == nil)
    #expect(step.drop == .commandCancelled)
  }

  @Test
  func commandFinishedNonZeroExit_firesWithFailureTitle() {
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 10
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 1, duration: Self.longDurationNs)),
      context: context
    )
    #expect(step.entry != nil)
    #expect(step.entry?.title.contains("failed") == true)
    #expect(step.entry?.title.contains("exit 1") == true)
  }

  @Test
  func keystrokeWithinOneSecond_suppresses() {
    let pane = PaneID()
    let now = Date()
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [pane: now.addingTimeInterval(-0.5)],
      now: now,
      commandFinishedThresholdSec: 1
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: 2 * 1_000_000_000)),
      context: context
    )
    #expect(step.entry == nil)
    #expect(step.drop == .userTypingRecently)
  }

  @Test
  func keystrokeOlderThanOneSecond_doesNotSuppress() {
    let pane = PaneID()
    let now = Date()
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [pane: now.addingTimeInterval(-1.5)],
      now: now,
      commandFinishedThresholdSec: 1
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: 2 * 1_000_000_000)),
      context: context
    )
    #expect(step.entry != nil)
    #expect(step.drop == nil)
  }

  @Test
  func keystrokeForDifferentPane_doesNotSuppress() {
    let pane = PaneID()
    let otherPane = PaneID()
    let now = Date()
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      lastUserKeystrokeAt: [otherPane: now.addingTimeInterval(-0.1)],
      now: now,
      commandFinishedThresholdSec: 1
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(pane, .commandFinished(exitCode: 0, duration: 2 * 1_000_000_000)),
      context: context
    )
    #expect(step.entry != nil)
    #expect(step.drop == nil)
  }

  @Test
  func outOfRangeThresholdInContextDoesNotCrash() {
    // The translator deliberately does not re-clamp; the input-validation
    // contract lives in `NotificationsSettings` decode (and the M3.T1 UI).
    // A zero threshold means every long-enough duration fires.
    let context = DetectionTranslator.Context(
      hasProducedOutput: [],
      commandFinishedThresholdSec: 0
    )
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 1_000_000_000)),
      context: context
    )
    #expect(step.entry != nil)
    #expect(step.drop == nil)
  }

  // MARK: - paneExited (deliberately not notified)

  @Test
  func paneExitedCleanProducesNoEntry() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneExited(pane, code: 0, signal: nil),
      hasProducedOutput: [pane]
    )
    #expect(step.entry == nil)
    // Cache management still runs so a recreated PaneID can't
    // inherit the prior 'has produced output' gate state.
    #expect(step.outputFlag == .clearProduced(pane))
  }

  @Test
  func paneExitedNonZeroProducesNoEntry() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneExited(pane, code: 1, signal: nil),
      hasProducedOutput: [pane]
    )
    #expect(step.entry == nil)
    #expect(step.outputFlag == .clearProduced(pane))
  }

  @Test
  func paneExitedBySignalProducesNoEntry() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneExited(pane, code: 0, signal: 9),
      hasProducedOutput: [pane]
    )
    #expect(step.entry == nil)
    #expect(step.outputFlag == .clearProduced(pane))
  }

  // MARK: - paneCrashed

  @Test
  func paneCrashedSurfacesReason() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneCrashed(pane, reason: "Subprocess panicked"),
      hasProducedOutput: [pane]
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.title == "Pane crashed")
    #expect(step.entry?.body == "Subprocess panicked")
    #expect(step.outputFlag == .clearProduced(pane))
  }

  // MARK: - paneIdle gating

  @Test
  func paneIdleBelowThresholdIsDropped() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneIdle(pane, duration: DetectionTranslator.idleThreshold - 1),
      hasProducedOutput: [pane]
    )
    #expect(step.entry == nil)
    #expect(step.outputFlag == .unchanged)
  }

  @Test
  func paneIdleAboveThresholdWithoutPriorOutputIsDropped() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneIdle(pane, duration: DetectionTranslator.idleThreshold + 60),
      hasProducedOutput: []  // pane has not produced anything yet
    )
    #expect(step.entry == nil)
  }

  @Test
  func paneIdleAboveThresholdWithPriorOutputIsTaskFinished() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneIdle(pane, duration: 45),
      hasProducedOutput: [pane]
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.title == "Pane idle")
    #expect(step.entry?.body == "No output for 45 s.")
  }

  // MARK: - non-notification events

  @Test
  func untrackedEventsProduceNoEntryAndNoFlagChange() {
    let cases: [TerminalEvent] = [
      .paneCreated(PaneID(), TabID()),
      .paneReady(PaneID()),
      .tabActivated(TabID()),
      .worktreeActivated(WorktreeID()),
      .hierarchyMutated(.catalog),
      .configChanged,
    ]
    for event in cases {
      let step = DetectionTranslator.translate(event, hasProducedOutput: [])
      #expect(step.entry == nil)
      #expect(step.outputFlag == .unchanged)
    }
  }

  @Test
  func paneInfoChangedWithUnrelatedDeltaIsIgnored() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .title("New title")),
      hasProducedOutput: []
    )
    #expect(step.entry == nil)
    #expect(step.outputFlag == .unchanged)
  }
}
