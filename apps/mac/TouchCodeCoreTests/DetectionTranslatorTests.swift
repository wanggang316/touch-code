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
  func desktopNotificationWithQuestionMarkIsWaitingForInput() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .desktopNotification(title: "Continue", body: "Apply migration?")),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .waitingForInput)
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

  @Test
  func commandFinishedZeroExitIsTaskFinished() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 0, duration: 1234)),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.body == "Command completed successfully.")
  }

  @Test
  func commandFinishedNonZeroExitMentionsStatus() {
    let step = DetectionTranslator.translate(
      .paneInfoChanged(PaneID(), .commandFinished(exitCode: 137, duration: 100)),
      hasProducedOutput: []
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.body == "Command exited with status 137.")
  }

  // MARK: - paneExited

  @Test
  func paneExitedCleanCarriesCleanBody() {
    let pane = PaneID()
    let step = DetectionTranslator.translate(
      .paneExited(pane, code: 0, signal: nil),
      hasProducedOutput: [pane]
    )
    #expect(step.entry?.kind == .taskFinished)
    #expect(step.entry?.body == "Pane exited cleanly.")
    #expect(step.outputFlag == .clearProduced(pane))
  }

  @Test
  func paneExitedNonZeroMentionsStatus() {
    let step = DetectionTranslator.translate(
      .paneExited(PaneID(), code: 1, signal: nil),
      hasProducedOutput: []
    )
    #expect(step.entry?.body == "Pane exited with status 1.")
  }

  @Test
  func paneExitedBySignalMentionsSignal() {
    let step = DetectionTranslator.translate(
      .paneExited(PaneID(), code: 0, signal: 9),
      hasProducedOutput: []
    )
    #expect(step.entry?.body == "Pane terminated by signal 9.")
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
