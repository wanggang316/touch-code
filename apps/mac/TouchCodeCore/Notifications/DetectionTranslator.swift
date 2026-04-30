import Foundation

/// Pure translation from a single `TerminalEvent` to a `Translation`
/// describing the inbox row that should be appended (or `nil` if the
/// event carries no notification value).
///
/// Splitting the translation logic out of the app-target
/// `NotificationDetector` lets `TouchCodeCoreTests` exercise the full
/// table without needing a `NotificationStore`, an `OSNotifier`, or a
/// live runtime. The orchestration (catalog walk → SourcePath, mute
/// label check, banner gating, store.append) stays in the detector.
public nonisolated enum DetectionTranslator {
  /// Lower bound on `paneIdle.duration` below which an idle event is
  /// treated as terminal noise (cursor blink, typing reset) rather than
  /// a "task quiet" signal worth notifying about.
  public static let idleThreshold: TimeInterval = 30

  /// One step's translation result. The detector also gets back a hint
  /// for whether to update its `hasProducedOutput` membership for the
  /// pane (so a pane that exits or crashes loses its "has produced
  /// output" flag and a freshly spawned pane reaches `paneOutput` before
  /// it can ever fire `paneIdle`).
  public struct Step: Equatable, Sendable {
    public let entry: Entry?
    public let outputFlag: OutputFlag

    public init(entry: Entry?, outputFlag: OutputFlag) {
      self.entry = entry
      self.outputFlag = outputFlag
    }
  }

  public struct Entry: Equatable, Sendable {
    public let paneID: PaneID
    public let kind: InboxEntry.Kind
    public let title: String
    public let body: String

    public init(paneID: PaneID, kind: InboxEntry.Kind, title: String, body: String) {
      self.paneID = paneID
      self.kind = kind
      self.title = title
      self.body = body
    }
  }

  public enum OutputFlag: Equatable, Sendable {
    /// Mark this pane as having produced output (gate for future idle).
    case markProduced(PaneID)
    /// Clear the pane's "has produced" flag — pane has gone away.
    case clearProduced(PaneID)
    /// No change to the output-produced map.
    case unchanged
  }

  /// Translate a single event. Returns `Step(entry: nil, outputFlag:
  /// ...)` when the event matters to bookkeeping but does not produce a
  /// notification; returns `Step(entry: ..., outputFlag: ...)` when it
  /// does.
  public static func translate(
    _ event: TerminalEvent,
    hasProducedOutput: Set<PaneID>
  ) -> Step {
    switch event {
    case .paneOutput(let paneID, _):
      return Step(entry: nil, outputFlag: .markProduced(paneID))

    case .paneInfoChanged(let paneID, let delta):
      switch delta {
      case .desktopNotification(let title, let body):
        return Step(
          entry: Entry(
            paneID: paneID,
            kind: classify(title: title, body: body),
            title: title,
            body: body
          ),
          outputFlag: .unchanged
        )
      case .bellRang:
        return Step(
          entry: Entry(
            paneID: paneID,
            kind: .waitingForInput,
            title: "Pane bell",
            body: "A pane rang the terminal bell."
          ),
          outputFlag: .unchanged
        )
      case .commandFinished(let exitCode, _):
        return Step(
          entry: Entry(
            paneID: paneID,
            kind: .taskFinished,
            title: "Command finished",
            body: exitCode == 0
              ? "Command completed successfully."
              : "Command exited with status \(exitCode)."
          ),
          outputFlag: .unchanged
        )
      default:
        return Step(entry: nil, outputFlag: .unchanged)
      }

    case .paneExited(let paneID, let code, let signal):
      let body: String
      if let signal {
        body = "Pane terminated by signal \(signal)."
      } else if code == 0 {
        body = "Pane exited cleanly."
      } else {
        body = "Pane exited with status \(code)."
      }
      return Step(
        entry: Entry(paneID: paneID, kind: .taskFinished, title: "Pane exited", body: body),
        outputFlag: .clearProduced(paneID)
      )

    case .paneCrashed(let paneID, let reason):
      return Step(
        entry: Entry(paneID: paneID, kind: .taskFinished, title: "Pane crashed", body: reason),
        outputFlag: .clearProduced(paneID)
      )

    case .paneIdle(let paneID, let duration):
      // Two gates: the idle has to be longer than the noise threshold
      // AND the pane must have produced output at some point — a
      // freshly spawned pane that never wrote anything cannot fire
      // a "task finished" idle.
      guard duration >= idleThreshold, hasProducedOutput.contains(paneID) else {
        return Step(entry: nil, outputFlag: .unchanged)
      }
      return Step(
        entry: Entry(
          paneID: paneID,
          kind: .taskFinished,
          title: "Pane idle",
          body: "No output for \(Int(duration.rounded())) s."
        ),
        outputFlag: .unchanged
      )

    case .paneClosedByTab(let paneID, _):
      // Tab autoclose tears down the pane without firing paneExited /
      // paneCrashed (engine path bypasses both). Clear the produced-
      // output flag so a recreated PaneID — defensive even though IDs
      // are UUIDs and shouldn't recur — cannot inherit the prior gate.
      return Step(entry: nil, outputFlag: .clearProduced(paneID))

    case .paneCreated, .paneReady,
      .tabActivated, .tabAutoClosed, .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      return Step(entry: nil, outputFlag: .unchanged)
    }
  }

  /// Heuristic: pick `.waitingForInput` for desktop notifications whose
  /// title or body suggests the agent needs the user (permission /
  /// approval / input). The trailing question-mark cue applies only at
  /// the very end of the title — body text routinely contains rhetorical
  /// `?` characters (e.g. "Built 5 targets. Add tests?") which would
  /// otherwise misclassify routine completion as input-required.
  public static func classify(title: String, body: String) -> InboxEntry.Kind {
    let combined = (title + " " + body).lowercased()
    let lexicalCues = ["permission", "approval", "approve", "input"]
    if lexicalCues.contains(where: combined.contains) {
      return .waitingForInput
    }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
      return .waitingForInput
    }
    return .taskFinished
  }
}
