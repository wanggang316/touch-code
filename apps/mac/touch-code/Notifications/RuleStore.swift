import Foundation
import os.log
import TouchCodeCore

/// Reads `detection-rules.json`, validates it, and materialises each rule
/// into a C3 `HookSubscription` in `hooks.json` via the `HookConfigWriting`
/// adapter. Uses read-modify-write over C3's existing `load()` / `save(_:)`
/// API (DEC-P1) — no new upsert API required from C3.
///
/// Rule → subscription translation (see design §Detection Rule DSL):
/// - `event` = `.panelOutputMatch` (the only C3 event we ride for detection)
/// - `matchPattern` = rule's regex or pipe-joined containsAny alternation
/// - `scope` = `.panelLabel("agent:<rule.agent>")` or `.panelID(rule.panelID)`
/// - `command` = `"__touch-code/internal:notifications:<rule.id>"`
/// - `mode` = `.fireAndForget`
/// - `timeoutSeconds` = 1 (unused; sentinel-prefix route short-circuits spawn)
@MainActor
final class RuleStore {
  private let fileURL: URL
  private let hookWriter: any HookConfigWriting
  private let logger = Logger(subsystem: "com.touch-code.notifications", category: "rules")

  init(
    fileURL: URL = ConfigPaths.detectionRules(),
    hookWriter: any HookConfigWriting
  ) {
    self.fileURL = fileURL
    self.hookWriter = hookWriter
  }

  /// Read rules, validate, materialise into hooks.json. Returns the loaded
  /// rules. Caller (app shell) hands them to `DetectionRouter` and
  /// `TemplateRenderer`.
  func loadAndMaterialise() throws -> AgentDetectionRules {
    let rules = try loadFromDisk()
    try validate(rules)
    try materialise(rules)
    return rules
  }

  /// Re-read from disk + re-materialise. Called by the coordinator's
  /// `reloadRules()` path (M4b). If the file is missing, regenerates
  /// the bundled defaults (DefaultRules.installIfMissing) per M6 policy.
  func reloadAndRematerialise() throws -> AgentDetectionRules {
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      try DefaultRules.installIfMissing(at: fileURL)
    }
    return try loadAndMaterialise()
  }

  // MARK: - Private

  private func loadFromDisk() throws -> AgentDetectionRules {
    if let loaded = try AtomicFileStore.read(AgentDetectionRules.self, at: fileURL) {
      return loaded
    }
    // Missing file → empty rule set (caller may then call reload to install defaults).
    return AgentDetectionRules()
  }

  private func validate(_ rules: AgentDetectionRules) throws {
    guard rules.version == AgentDetectionRules.currentVersion else {
      throw RuleStoreError.unsupportedVersion(rules.version)
    }
    for rule in rules.rules {
      // The AgentDetectionRules decoder already throws .missingMatch for
      // malformed rules; this pass catches anything constructed in memory.
      if rule.appliesWhen.hookEvent == .panelOutputMatch, rule.match == nil {
        throw RuleStoreError.missingMatch(ruleID: rule.id)
      }
      if let match = rule.match, case .regex(let pattern, _) = match {
        do {
          _ = try NSRegularExpression(pattern: pattern)
        } catch {
          throw RuleStoreError.invalidRegex(ruleID: rule.id, pattern: pattern)
        }
      }
    }
    // Templates are validated by constructing a renderer — any malformed
    // template surfaces here as a RuleStoreError.
    _ = try TemplateRenderer(rules: rules)
  }

  /// Materialise every rule as a sentinel-prefixed `HookSubscription`
  /// via C3's reserved-namespace API (revised DEC-P1). `upsertInternal`
  /// is atomic on C3's side — no retry loop, no load-filter-append
  /// dance, no risk of C3 silently dropping our own rows on next load
  /// because it validates the reserved prefix rather than filtering
  /// it. Stale sentinel rows from removed rules are cleared by the
  /// leading `removeInternal` so only the current rule set survives.
  private func materialise(_ rules: AgentDetectionRules) throws {
    try hookWriter.removeInternal(idsPrefixed: Self.sentinelPrefix)
    let newSubscriptions = rules.rules.map { Self.makeSubscription(from: $0) }
    if !newSubscriptions.isEmpty {
      try hookWriter.upsertInternal(newSubscriptions)
    }
  }

  // MARK: - Helpers

  static let sentinelPrefix = "__touch-code/internal:notifications:"

  static func isNotificationsSentinel(_ command: String) -> Bool {
    command.hasPrefix(sentinelPrefix)
  }

  static func makeSubscription(from rule: AgentDetectionRules.Rule) -> HookSubscription {
    let scope: HookSubscription.Scope = {
      if let panelID = rule.appliesWhen.panelID {
        return .panelID(panelID)
      }
      return .panelLabel("agent:\(rule.agent)")
    }()
    let (pattern, flags) = Self.patternAndFlags(for: rule.match)
    return HookSubscription(
      id: UUID(),
      event: .panelOutputMatch,
      command: "\(sentinelPrefix)\(rule.id)",
      matchPattern: pattern,
      matchFlags: flags,
      scope: scope,
      timeoutSeconds: 1,
      mode: .fireAndForget,
      cwd: nil,
      env: [:],
      allowRawOutput: false,
      allowRawInput: false,
      idleThresholdSeconds: nil,
      disabled: false
    )
  }

  static func patternAndFlags(
    for match: AgentDetectionRules.Match?
  ) -> (String?, HookSubscription.RegexFlags) {
    guard let match else { return (nil, []) }
    switch match {
    case .containsAny(let literals):
      // Escape each literal then join as alternation. Fire dispatcher-side
      // regex-compile errors, not silent behaviour drift.
      let alternatives = literals
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")
      return ("(?:\(alternatives))", [])
    case .regex(let pattern, _):
      // The `on:` target (tail / lastLine / lastNonEmptyLine) is a C6-side
      // post-filter; C3 matches against the full output batch. The
      // DetectionRouter applies the narrower target check at fire time.
      return (pattern, [])
    }
  }
}
