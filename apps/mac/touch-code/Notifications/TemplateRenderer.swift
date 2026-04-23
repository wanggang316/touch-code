import Foundation
import TouchCodeCore

/// Pure function from `(template, envelope, transition) -> String` with
/// load-time field-set validation. The renderer is constructed from an
/// `AgentDetectionRules` snapshot: every `{path}` placeholder in every
/// rule's `title` / `body` is checked against
/// `TemplateField.validPaths(for: rule.appliesWhen.hookEvent)` and
/// offenders cause init to throw. This means the dispatcher never sees
/// a malformed template at fire time.
///
/// Template grammar (design §Detection Rule DSL):
/// - `{path.like.this}` — field lookup.
/// - `{path | filter[: arg]}` — optional single filter. Filter is one of:
///   `truncate: Int`, `firstLine`, `default: "<string>"`, `upper`, `lower`.
/// - Multiple filters chain left-to-right with `|`.
///
/// Unknown field paths throw `RuleStoreError.unknownTemplateField`.
/// Unknown filter names throw `RuleStoreError.unknownFilter`.
/// Malformed placeholder syntax throws `RuleStoreError.malformedTemplate`.
nonisolated struct TemplateRenderer {
  /// Init validates every rule's title/body against the field set for its
  /// `appliesWhen.hookEvent`. Rules without a `hookEvent` treat every
  /// field as potentially available (the router can still drop at
  /// runtime if a field is actually missing from the envelope).
  init(rules: AgentDetectionRules) throws {
    for rule in rules.rules {
      let valid: Set<TemplateField> = {
        if let event = rule.appliesWhen.hookEvent {
          return TemplateField.validPaths(for: event)
        }
        return Set(TemplateField.allCases)
      }()
      try Self.validate(template: rule.title, ruleID: rule.id, against: valid)
      try Self.validate(template: rule.body, ruleID: rule.id, against: valid)
    }
  }

  /// Render a template string against the supplied envelope + transition.
  /// Unresolved placeholders evaluate to the empty string unless a
  /// `default` filter is applied.
  func render(
    template: String,
    for envelope: HookEnvelope,
    transition: AgentStateTransition,
    agent: String
  ) -> String {
    var out = ""
    out.reserveCapacity(template.count)
    var iterator = template.startIndex
    let end = template.endIndex
    while iterator < end {
      let remaining = template[iterator..<end]
      guard let open = remaining.firstIndex(of: "{") else {
        out += remaining
        break
      }
      out += template[iterator..<open]
      guard let close = template[open..<end].firstIndex(of: "}") else {
        // Dangling `{`; copy verbatim.
        out += template[open..<end]
        break
      }
      let raw = template[template.index(after: open)..<close]
      let resolved = Self.resolve(
        placeholder: String(raw),
        envelope: envelope,
        transition: transition,
        agent: agent
      )
      out += resolved
      iterator = template.index(after: close)
    }
    return out
  }

  // MARK: - Validation

  private static func validate(
    template: String,
    ruleID: String,
    against valid: Set<TemplateField>
  ) throws {
    var iterator = template.startIndex
    while iterator < template.endIndex {
      let remaining = template[iterator..<template.endIndex]
      guard let open = remaining.firstIndex(of: "{") else { return }
      guard let close = template[open..<template.endIndex].firstIndex(of: "}") else {
        throw RuleStoreError.malformedTemplate(ruleID: ruleID, fragment: String(template[open...]))
      }
      let raw = String(template[template.index(after: open)..<close])
      let parts = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      guard let pathString = parts.first, !pathString.isEmpty else {
        throw RuleStoreError.malformedTemplate(ruleID: ruleID, fragment: "{\(raw)}")
      }
      if let field = TemplateField(rawValue: pathString) {
        if !valid.contains(field) {
          throw RuleStoreError.unknownTemplateField(ruleID: ruleID, path: pathString)
        }
      } else {
        throw RuleStoreError.unknownTemplateField(ruleID: ruleID, path: pathString)
      }
      for filter in parts.dropFirst() {
        try validateFilter(String(filter), ruleID: ruleID)
      }
      iterator = template.index(after: close)
    }
  }

  private static func validateFilter(_ filter: String, ruleID: String) throws {
    let head = filter.split(separator: ":", maxSplits: 1).first.map(String.init) ?? filter
    let normalized = head.trimmingCharacters(in: .whitespaces)
    switch normalized {
    case "truncate", "firstLine", "default", "upper", "lower":
      return
    default:
      throw RuleStoreError.unknownFilter(ruleID: ruleID, filter: normalized)
    }
  }

  // MARK: - Resolution

  private static func resolve(
    placeholder: String,
    envelope: HookEnvelope,
    transition: AgentStateTransition,
    agent: String
  ) -> String {
    let parts = placeholder.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let pathString = parts.first else { return "" }
    var value = lookup(path: pathString, envelope: envelope, transition: transition, agent: agent) ?? ""
    for filter in parts.dropFirst() {
      value = applyFilter(filter, to: value)
    }
    return value
  }

  // swiftlint:disable:next cyclomatic_complexity
  private static func lookup(
    path: String,
    envelope: HookEnvelope,
    transition: AgentStateTransition,
    agent: String
  ) -> String? {
    guard let field = TemplateField(rawValue: path) else { return nil }
    switch field {
    // Anchors
    case .agent: return agent
    case .stateFrom: return transition.from.rawValue
    case .stateTo: return transition.to.rawValue
    case .paneID: return envelope.pane?.id.raw.uuidString
    case .paneWorkingDirectory: return envelope.pane?.workingDirectory
    case .paneInitialCommand: return envelope.pane?.initialCommand
    case .tabID: return envelope.tab?.id.raw.uuidString
    case .tabName: return envelope.tab?.name
    case .tabSelectedPaneID: return envelope.tab?.selectedPaneID?.raw.uuidString
    case .worktreeID: return envelope.worktree?.id.raw.uuidString
    case .worktreeName: return envelope.worktree?.name
    case .worktreePath: return envelope.worktree?.path
    case .worktreeBranch: return envelope.worktree?.branch
    case .projectID: return envelope.project?.id.raw.uuidString
    case .projectName: return envelope.project?.name
    case .projectRootPath: return envelope.project?.rootPath
    case .spaceID: return envelope.space?.id.raw.uuidString
    case .spaceName: return envelope.space?.name
    // Event data
    default:
      return resolveData(field: field, envelope: envelope)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private static func resolveData(field: TemplateField, envelope: HookEnvelope) -> String? {
    switch envelope.data {
    case .paneCreated(let via):
      if field == .dataCreatedVia { return via }
    case .paneReady(let pid, let shell):
      if field == .dataPID { return pid.map(String.init) ?? "" }
      if field == .dataShell { return shell }
    case .paneInput(let text, let bytes):
      if field == .dataText { return text }
      if field == .dataInputBytes { return String(bytes) }
    case .paneOutput(let output, let bytes):
      if field == .dataOutput { return String(data: output, encoding: .utf8) ?? "" }
      if field == .dataOutputBytes { return String(bytes) }
    case .paneOutputMatch(let match, let range, let output, let bytes):
      if field == .dataMatch { return match }
      if field == .dataOutput { return String(data: output, encoding: .utf8) ?? "" }
      if field == .dataOutputBytes { return String(bytes) }
      if field == .dataMatchedRangeStart { return String(range.start) }
      if field == .dataMatchedRangeLength { return String(range.length) }
    case .paneIdle(let idle, let sinceOut, let sinceIn):
      if field == .dataIdleSeconds { return String(idle) }
      if field == .dataSinceLastOutput { return String(sinceOut) }
      if field == .dataSinceLastInput { return String(sinceIn) }
    case .paneExited(let code):
      if field == .dataExitCode { return String(code) }
    case .paneCrashed(let reason):
      if field == .dataReason { return reason }
    case .tabActivated(let prev):
      if field == .dataPreviousTabID { return prev?.raw.uuidString ?? "" }
    case .tabDeactivated(let next):
      if field == .dataNextTabID { return next?.raw.uuidString ?? "" }
    case .tabAutoClosed(let reason, let count, let window):
      if field == .dataReason { return reason }
      if field == .dataCrashCount { return String(count) }
      if field == .dataWindowSeconds { return String(window) }
    case .worktreeActivated(let prev):
      if field == .dataPreviousWorktreeID { return prev?.raw.uuidString ?? "" }
    case .worktreeDeactivated(let next):
      if field == .dataNextWorktreeID { return next?.raw.uuidString ?? "" }
    case .worktreeCreated(let branch, let gitExit):
      if field == .dataBranch { return branch ?? "" }
      if field == .dataGitExit { return gitExit.map(String.init) ?? "" }
    case .worktreeRemoved(let keep):
      if field == .dataKeepDirectory { return String(keep) }
    }
    return nil
  }

  // MARK: - Filters

  private static func applyFilter(_ filter: String, to value: String) -> String {
    let parts = filter.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    let name = parts[0]
    let argument = parts.count > 1 ? parts[1] : nil
    switch name {
    case "truncate":
      guard let arg = argument, let n = Int(arg) else { return value }
      return Self.truncateToGraphemes(value, limit: n)
    case "firstLine":
      return value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    case "default":
      if value.isEmpty { return Self.stripQuotes(argument ?? "") }
      return value
    case "upper":
      return value.uppercased()
    case "lower":
      return value.lowercased()
    default:
      return value
    }
  }

  private static func truncateToGraphemes(_ value: String, limit: Int) -> String {
    if limit <= 0 { return "" }
    let clusters = Array(value)
    if clusters.count <= limit { return value }
    return String(clusters.prefix(limit))
  }

  private static func stripQuotes(_ arg: String) -> String {
    if arg.hasPrefix("\"") && arg.hasSuffix("\"") && arg.count >= 2 {
      return String(arg.dropFirst().dropLast())
    }
    return arg
  }
}

/// Errors raised by `TemplateRenderer.init` and surfaced further up by
/// `RuleStore.loadAndMaterialise`. No `hooksFileBusy` variant: C3's
/// `upsertInternal` is atomic on its side; contention is C3's problem,
/// not ours (revised DEC-P1).
nonisolated enum RuleStoreError: Error, Equatable {
  case unknownTemplateField(ruleID: String, path: String)
  case unknownFilter(ruleID: String, filter: String)
  case malformedTemplate(ruleID: String, fragment: String)
  case invalidRegex(ruleID: String, pattern: String)
  case unsupportedVersion(Int)
  case missingMatch(ruleID: String)
}
