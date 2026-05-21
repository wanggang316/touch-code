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
    public let drop: InboxDropReason?

    public init(entry: Entry?, outputFlag: OutputFlag, drop: InboxDropReason? = nil) {
      self.entry = entry
      self.outputFlag = outputFlag
      self.drop = drop
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

    /// Whether this flag corresponds to a terminal teardown event —
    /// `paneExited` / `paneCrashed` / `paneClosedByTab`. Lets the
    /// detector drop its source-path cache after the final emit.
    public var isTeardown: Bool {
      switch self {
      case .clearProduced: return true
      case .markProduced, .unchanged: return false
      }
    }
  }

  /// Backward-compatible overload used by call sites that have not yet
  /// adopted `Context`. Constructs a `Context` with default
  /// commandFinished settings and an empty keystroke map. M5.T1 will swap
  /// `NotificationDetector` to the `Context`-aware path; until then this
  /// keeps the detector compiling unchanged.
  public static func translate(
    _ event: TerminalEvent,
    hasProducedOutput: Set<PaneID>
  ) -> Step {
    translate(event, context: Context(hasProducedOutput: hasProducedOutput))
  }

  /// Translate a single event. Returns `Step(entry: nil, outputFlag:
  /// ...)` when the event matters to bookkeeping but does not produce a
  /// notification; returns `Step(entry: ..., outputFlag: ...)` when it
  /// does. May also set `Step.drop` to record why a candidate
  /// notification was suppressed at the translator layer.
  public static func translate(
    _ event: TerminalEvent,
    context: Context
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
      case .commandFinished(let exitCode, let durationNs):
        return translateCommandFinished(
          paneID: paneID,
          exitCode: exitCode,
          durationNs: durationNs,
          context: context
        )
      default:
        return Step(entry: nil, outputFlag: .unchanged)
      }

    case .paneExited(let paneID, _, _):
      // Pane exits don't notify — explicit closes (close-pane
      // binding) and natural command completion are both expected,
      // user-initiated transitions. Crashes (paneCrashed below)
      // and post-busy idle (paneIdle) still cover the genuine
      // "needs your attention" cases. Cache cleanup still runs
      // so a recreated PaneID can never inherit stale gate state.
      return Step(entry: nil, outputFlag: .clearProduced(paneID))

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
      guard duration >= idleThreshold, context.hasProducedOutput.contains(paneID) else {
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

  /// Command-finished branch lifted out of `translate` to keep the main
  /// switch under SwiftLint's cyclomatic-complexity budget. Implements
  /// the M4.T1 suppression chain — feature flag, user-cancellation,
  /// duration threshold, recent-keystroke window — and emits a
  /// differential success / failure title when the event survives.
  private static func translateCommandFinished(
    paneID: PaneID,
    exitCode: Int32,
    durationNs: UInt64,
    context: Context
  ) -> Step {
    // 1. Feature toggle.
    guard context.commandFinishedEnabled else {
      return Step(entry: nil, outputFlag: .unchanged, drop: .commandFinishedDisabled)
    }
    // 2. User-cancellation suppression. SIGINT (130) and SIGTERM (143)
    //    on a POSIX shell mean the user already knows the command
    //    ended; a banner would be redundant.
    if exitCode == 130 || exitCode == 143 {
      return Step(entry: nil, outputFlag: .unchanged, drop: .commandCancelled)
    }
    // 3. Duration threshold. durationNs is nanoseconds; threshold is
    //    seconds.
    let durationSec = Double(durationNs) / 1_000_000_000
    guard durationSec >= Double(context.commandFinishedThresholdSec) else {
      return Step(entry: nil, outputFlag: .unchanged, drop: .commandFinishedShort)
    }
    // 4. Recent-keystroke suppression. If the user typed into the pane
    //    within the last 1 s the command-finished event is likely the
    //    user pressing Enter on the next prompt rather than a
    //    long-running task completing without observation. The 1 s
    //    window is hardcoded; M5.T1 wires the actual keystroke source.
    if let lastKey = context.lastUserKeystrokeAt[paneID],
      context.now.timeIntervalSince(lastKey) < 1.0
    {
      return Step(entry: nil, outputFlag: .unchanged, drop: .userTypingRecently)
    }
    // 5. Differential title for non-zero exit.
    let durationLabel = formatDuration(durationSec)
    let (title, body): (String, String) =
      exitCode == 0
      ? ("Command finished", "Completed in \(durationLabel).")
      : ("Command failed (exit \(exitCode))", "Ran for \(durationLabel) before failing.")
    return Step(
      entry: Entry(paneID: paneID, kind: .taskFinished, title: title, body: body),
      outputFlag: .unchanged,
      drop: nil
    )
  }

  /// Compact human-readable duration for inbox bodies. `< 60 s` renders
  /// as `Ns`, `< 1 h` as `Nm[ Ns]`, otherwise `Nh[ Nm]`.
  private static func formatDuration(_ seconds: Double) -> String {
    if seconds < 60 { return "\(Int(seconds.rounded())) s" }
    let minutes = Int(seconds / 60)
    let remainSec = Int(seconds) % 60
    if minutes < 60 { return remainSec == 0 ? "\(minutes) m" : "\(minutes) m \(remainSec) s" }
    let hours = minutes / 60
    let remainMin = minutes % 60
    return remainMin == 0 ? "\(hours) h" : "\(hours) h \(remainMin) m"
  }
}

extension DetectionTranslator {
  /// Per-event context the translator needs but cannot derive from the
  /// event alone: pane-level "has produced output" gate (for idle), a
  /// per-pane "last user keystroke at" map and current time (for the
  /// command-finished keystroke-suppression window), and the relevant
  /// `NotificationsSettings` knobs (so the translator stays pure and the
  /// app layer owns the settings lifecycle).
  public struct Context: Equatable, Sendable {
    public let hasProducedOutput: Set<PaneID>
    public let lastUserKeystrokeAt: [PaneID: Date]
    public let now: Date
    public let commandFinishedEnabled: Bool
    public let commandFinishedThresholdSec: Int

    public init(
      hasProducedOutput: Set<PaneID>,
      lastUserKeystrokeAt: [PaneID: Date] = [:],
      now: Date = Date(),
      commandFinishedEnabled: Bool = true,
      commandFinishedThresholdSec: Int = 10
    ) {
      self.hasProducedOutput = hasProducedOutput
      self.lastUserKeystrokeAt = lastUserKeystrokeAt
      self.now = now
      self.commandFinishedEnabled = commandFinishedEnabled
      self.commandFinishedThresholdSec = commandFinishedThresholdSec
    }
  }
}
