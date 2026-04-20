import Foundation

/// One FSM transition produced by an `AgentStateTracker`. Fed to the
/// `NotificationCoordinator` which decides (per muting policy) whether the
/// transition is surfaced as an OS banner in addition to landing in the inbox.
///
/// `trigger` captures *what* drove the transition — a matched detection rule,
/// a C3 envelope delivered directly (lifecycle signals `.panelExited`,
/// `.panelCrashed`), the tracker-local idle timer, or a user override via
/// CLI/UI. Coordinators consult this to decide notification template selection
/// (`.rule` uses the rule's `title`/`body`; `.envelope` uses built-in copy
/// keyed to the event; `.userOverride` never notifies per design invariant).
public nonisolated struct AgentStateTransition: Equatable, Codable, Sendable {
  public let panelID: PanelID
  public let from: AgentState
  public let to: AgentState
  public let at: Date
  public let trigger: Trigger

  public init(
    panelID: PanelID,
    from: AgentState,
    to: AgentState,
    at: Date,
    trigger: Trigger
  ) {
    self.panelID = panelID
    self.from = from
    self.to = to
    self.at = at
    self.trigger = trigger
  }

  public enum Trigger: Equatable, Sendable {
    /// A user-configured detection rule matched a `.panelOutputMatch` envelope.
    case rule(id: String)
    /// A lifecycle envelope drove the transition directly — typically
    /// `.panelExited` (→ `.completed`) or `.panelCrashed` (→ teardown path).
    case envelope(event: HookEvent)
    /// The tracker-local idle timer fired after `idleThresholdSeconds`.
    case idleTimer(seconds: TimeInterval)
    /// Manual state change from CLI (`tc notifications override`) or UI.
    /// Never emits a notification per design invariant.
    case userOverride
  }
}

extension AgentStateTransition.Trigger: Codable {
  private enum CodingKeys: String, CodingKey { case kind, id, event, seconds }

  private enum Kind: String, Codable {
    case rule, envelope, idleTimer, userOverride
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .rule:
      self = .rule(id: try container.decode(String.self, forKey: .id))
    case .envelope:
      self = .envelope(event: try container.decode(HookEvent.self, forKey: .event))
    case .idleTimer:
      self = .idleTimer(seconds: try container.decode(TimeInterval.self, forKey: .seconds))
    case .userOverride:
      self = .userOverride
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .rule(let id):
      try container.encode(Kind.rule, forKey: .kind)
      try container.encode(id, forKey: .id)
    case .envelope(let event):
      try container.encode(Kind.envelope, forKey: .kind)
      try container.encode(event, forKey: .event)
    case .idleTimer(let seconds):
      try container.encode(Kind.idleTimer, forKey: .kind)
      try container.encode(seconds, forKey: .seconds)
    case .userOverride:
      try container.encode(Kind.userOverride, forKey: .kind)
    }
  }
}
