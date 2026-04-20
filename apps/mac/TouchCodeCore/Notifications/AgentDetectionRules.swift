import Foundation

/// On-disk shape of `~/.config/touch-code/detection-rules.json` — the
/// C6-owned file that maps user-authored detection rules into C3
/// `HookSubscription`s via the sentinel-prefix route (`RuleStore` in M2).
///
/// A rule matches when (a) its `appliesWhen` predicates pass — at minimum
/// `panelLabelledAgent` corresponds to a Panel label like `"agent:claude"`,
/// and `hookEvent` scopes to one `HookEvent` case — and (b) for
/// `.panelOutputMatch`-scoped rules, its `match` regex/literal hits the
/// rolling output tail. Matches fire a state transition via
/// `transitionTo`; `title`/`body` template strings are rendered by
/// `TemplateRenderer` (M2) at fire time and handed to the notification
/// coordinator.
///
/// Schema evolution follows the architecture invariant: readers abort on
/// unknown `version` rather than silently upgrade. `missingMatch(ruleID:)`
/// catches the rule-level invariant "any `.panelOutputMatch` rule must
/// carry a `match`" at load time so malformed rules never reach the
/// dispatcher.
public nonisolated struct AgentDetectionRules: Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var idleThresholdSeconds: TimeInterval
  public var rules: [Rule]

  public init(
    version: Int = AgentDetectionRules.currentVersion,
    idleThresholdSeconds: TimeInterval = 120,
    rules: [Rule] = []
  ) {
    self.version = version
    self.idleThresholdSeconds = idleThresholdSeconds
    self.rules = rules
  }

  public struct Rule: Equatable, Codable, Sendable {
    public let id: String
    public let agent: String
    public let appliesWhen: AppliesWhen
    public let match: Match?
    public let transitionTo: AgentState
    public let title: String
    public let body: String

    public init(
      id: String,
      agent: String,
      appliesWhen: AppliesWhen,
      match: Match? = nil,
      transitionTo: AgentState,
      title: String,
      body: String
    ) {
      self.id = id
      self.agent = agent
      self.appliesWhen = appliesWhen
      self.match = match
      self.transitionTo = transitionTo
      self.title = title
      self.body = body
    }
  }

  public struct AppliesWhen: Equatable, Codable, Sendable {
    public var panelLabelledAgent: String?
    public var hookEvent: HookEvent?
    public var panelID: PanelID?

    public init(
      panelLabelledAgent: String? = nil,
      hookEvent: HookEvent? = nil,
      panelID: PanelID? = nil
    ) {
      self.panelLabelledAgent = panelLabelledAgent
      self.hookEvent = hookEvent
      self.panelID = panelID
    }
  }

  /// Pattern-match spec for `.panelOutputMatch` rules. `containsAny` is a cheap
  /// literal-substring check; `regex` takes an ECMA-262 pattern + `on` selector
  /// controlling which portion of the output tail is matched.
  public enum Match: Equatable, Sendable {
    case containsAny([String])
    case regex(pattern: String, on: Target)

    public enum Target: String, Codable, Sendable {
      case tail
      case lastLine
      case lastNonEmptyLine
    }
  }

  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
    /// A `.panelOutputMatch`-scoped rule is missing its `match` spec.
    /// Rejected at load time so the dispatcher never sees a malformed rule.
    case missingMatch(ruleID: String)
  }
}

extension AgentDetectionRules: Codable {
  private enum CodingKeys: String, CodingKey {
    case version, idleThresholdSeconds, rules
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == AgentDetectionRules.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    let rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    // Enforce the rule-level invariant at load time.
    for rule in rules {
      if rule.appliesWhen.hookEvent == .panelOutputMatch, rule.match == nil {
        throw DecodingIssue.missingMatch(ruleID: rule.id)
      }
    }
    self.version = version
    self.idleThresholdSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleThresholdSeconds) ?? 120
    self.rules = rules
  }
}

extension AgentDetectionRules.Match: Codable {
  private enum CodingKeys: String, CodingKey {
    case containsAny
    case regex
    case on
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let values = try container.decodeIfPresent([String].self, forKey: .containsAny) {
      self = .containsAny(values)
      return
    }
    if let pattern = try container.decodeIfPresent(String.self, forKey: .regex) {
      let target = try container.decodeIfPresent(Target.self, forKey: .on) ?? .tail
      self = .regex(pattern: pattern, on: target)
      return
    }
    throw DecodingError.dataCorruptedError(
      forKey: .containsAny,
      in: container,
      debugDescription: "Match must specify either `containsAny` or `regex`."
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .containsAny(let values):
      try container.encode(values, forKey: .containsAny)
    case .regex(let pattern, let target):
      try container.encode(pattern, forKey: .regex)
      try container.encode(target, forKey: .on)
    }
  }
}
