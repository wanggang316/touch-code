import Foundation

/// Every valid template placeholder `{path.like.this}` a detection-rule
/// author can use in their `title` / `body` strings. Referenced by the
/// `TemplateRenderer` in M2 at rule-load time: any `{…}` literal the
/// renderer encounters must be a `TemplateField.rawValue`, or loading
/// throws `RuleStoreError.unknownTemplateField(ruleID:path:)`.
///
/// Field set is partitioned into:
/// - **Always available** — context anchors every envelope carries
///   (`agent`, `state.*`, `pane.*`, `tab.*`, `worktree.*`, `project.*`,
///   `space.*`). Returned for every `HookEvent`.
/// - **Event-specific `data.*` fields** — shape-bound to the matching
///   `HookEventData` case. Returned from `validPaths(for:)` only when
///   the rule's `appliesWhen.hookEvent` is that case.
///
/// The per-event sets mirror `HookEventData`'s associated-value shape
/// one-for-one. Adding a new `HookEvent` case requires extending both
/// the enum below and the switch in `validPaths(for:)`; omitting the
/// update keeps the rule-author surface conservative (always-available
/// anchors) rather than accidentally exposing wrong fields.
public nonisolated enum TemplateField: String, CaseIterable, Hashable, Sendable {
  // MARK: - Always available

  case agent
  case stateFrom = "state.from"
  case stateTo = "state.to"

  case paneID = "pane.id"
  case paneWorkingDirectory = "pane.workingDirectory"
  case paneInitialCommand = "pane.initialCommand"

  case tabID = "tab.id"
  case tabName = "tab.name"
  case tabSelectedPaneID = "tab.selectedPaneID"

  case worktreeID = "worktree.id"
  case worktreeName = "worktree.name"
  case worktreePath = "worktree.path"
  case worktreeBranch = "worktree.branch"

  case projectID = "project.id"
  case projectName = "project.name"
  case projectRootPath = "project.rootPath"

  // MARK: - pane.created

  case dataCreatedVia = "data.createdVia"

  // MARK: - pane.ready

  case dataPID = "data.pid"
  case dataShell = "data.shell"

  // MARK: - pane.input

  case dataText = "data.text"
  case dataInputBytes = "data.inputBytes"

  // MARK: - pane.output / pane.outputMatch

  case dataOutput = "data.output"
  case dataOutputBytes = "data.outputBytes"
  case dataMatch = "data.match"
  case dataMatchedRangeStart = "data.matchedRange.start"
  case dataMatchedRangeLength = "data.matchedRange.length"

  // MARK: - pane.idle

  case dataIdleSeconds = "data.idleSeconds"
  case dataSinceLastOutput = "data.sinceLastOutput"
  case dataSinceLastInput = "data.sinceLastInput"

  // MARK: - pane.exited

  case dataExitCode = "data.exitCode"

  // MARK: - pane.crashed / tab.autoClosed

  case dataReason = "data.reason"

  // MARK: - tab.activated / tab.deactivated

  case dataPreviousTabID = "data.previousTabID"
  case dataNextTabID = "data.nextTabID"

  // MARK: - tab.autoClosed

  case dataCrashCount = "data.crashCount"
  case dataWindowSeconds = "data.windowSeconds"

  // MARK: - worktree.activated / worktree.deactivated

  case dataPreviousWorktreeID = "data.previousWorktreeID"
  case dataNextWorktreeID = "data.nextWorktreeID"

  // MARK: - worktree.created

  case dataBranch = "data.branch"
  case dataGitExit = "data.gitExit"

  // MARK: - worktree.removed

  case dataKeepDirectory = "data.keepDirectory"

  /// The union of anchor fields every envelope carries.
  public static let alwaysAvailable: Set<TemplateField> = [
    .agent, .stateFrom, .stateTo,
    .paneID, .paneWorkingDirectory, .paneInitialCommand,
    .tabID, .tabName, .tabSelectedPaneID,
    .worktreeID, .worktreeName, .worktreePath, .worktreeBranch,
    .projectID, .projectName, .projectRootPath,
  ]

  /// Legal template placeholders for a rule whose `appliesWhen.hookEvent` is
  /// `event`. Always includes `alwaysAvailable`; adds the `data.*` subset
  /// matching the event's `HookEventData` case.
  public static func validPaths(for event: HookEvent) -> Set<TemplateField> {
    var paths = alwaysAvailable
    switch event {
    case .paneCreated:
      paths.insert(.dataCreatedVia)
    case .paneReady:
      paths.formUnion([.dataPID, .dataShell])
    case .paneInput:
      paths.formUnion([.dataText, .dataInputBytes])
    case .paneOutput:
      paths.formUnion([.dataOutput, .dataOutputBytes])
    case .paneOutputMatch:
      paths.formUnion([
        .dataMatch, .dataOutput, .dataOutputBytes,
        .dataMatchedRangeStart, .dataMatchedRangeLength,
      ])
    case .paneIdle:
      paths.formUnion([.dataIdleSeconds, .dataSinceLastOutput, .dataSinceLastInput])
    case .paneExited:
      paths.insert(.dataExitCode)
    case .paneCrashed:
      paths.insert(.dataReason)
    case .tabActivated:
      paths.insert(.dataPreviousTabID)
    case .tabDeactivated:
      paths.insert(.dataNextTabID)
    case .tabAutoClosed:
      paths.formUnion([.dataReason, .dataCrashCount, .dataWindowSeconds])
    case .worktreeActivated:
      paths.insert(.dataPreviousWorktreeID)
    case .worktreeDeactivated:
      paths.insert(.dataNextWorktreeID)
    case .worktreeCreated:
      paths.formUnion([.dataBranch, .dataGitExit])
    case .worktreeRemoved:
      paths.insert(.dataKeepDirectory)
    }
    return paths
  }
}
