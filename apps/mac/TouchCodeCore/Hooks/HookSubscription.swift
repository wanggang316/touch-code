import Foundation

/// One row in `hooks.json`. Users author these by hand or via
/// `tc hook install`; first-party consumers (C6) install them through
/// `HookConfigStore.upsertInternal(_:)` with a `command` in the reserved
/// `__touch-code/internal:` namespace.
public nonisolated struct HookSubscription: Equatable, Sendable, Identifiable {
  public var id: UUID
  public var event: HookEvent
  public var command: String
  public var matchPattern: String?
  public var matchFlags: RegexFlags
  public var scope: Scope
  public var timeoutSeconds: Double
  public var mode: Mode
  public var cwd: String?
  public var env: [String: String]
  public var allowRawOutput: Bool
  public var allowRawInput: Bool
  public var idleThresholdSeconds: Double?
  /// `true` when the subscription is temporarily suppressed (e.g. by the
  /// rate-limiter or a user `tc hook disable` call). **Note the inversion:**
  /// the `hook.enable` RPC carries `{ id, enabled: Bool }`; the app-side
  /// handler translates `enabled: true` → `disabled = false` before
  /// mutating this field. Keep the storage-level name to match the design
  /// doc's JSON schema (`"disabled": Bool`).
  public var disabled: Bool

  public init(
    id: UUID = UUID(),
    event: HookEvent,
    command: String,
    matchPattern: String? = nil,
    matchFlags: RegexFlags = [],
    scope: Scope = .anyPane,
    timeoutSeconds: Double = 5,
    mode: Mode = .fireAndForget,
    cwd: String? = nil,
    env: [String: String] = [:],
    allowRawOutput: Bool = false,
    allowRawInput: Bool = false,
    idleThresholdSeconds: Double? = nil,
    disabled: Bool = false
  ) {
    self.id = id
    self.event = event
    self.command = command
    self.matchPattern = matchPattern
    self.matchFlags = matchFlags
    self.scope = scope
    self.timeoutSeconds = timeoutSeconds
    self.mode = mode
    self.cwd = cwd
    self.env = env
    self.allowRawOutput = allowRawOutput
    self.allowRawInput = allowRawInput
    self.idleThresholdSeconds = idleThresholdSeconds
    self.disabled = disabled
  }

  public enum Mode: String, Codable, Hashable, Sendable {
    case fireAndForget
    case awaitActions
  }

  public struct RegexFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let caseInsensitive = RegexFlags(rawValue: 1 << 0)
    public static let multiline = RegexFlags(rawValue: 1 << 1)
    public static let dotAll = RegexFlags(rawValue: 1 << 2)
  }

  public enum Scope: Equatable, Sendable {
    case anyPane
    case paneID(PaneID)
    case paneLabel(String)
    case tabID(TabID)
    case tabLabel(String)
    case worktreeID(WorktreeID)
    case worktreePathGlob(String)
  }
}

// MARK: - Codable (HookSubscription + Scope)

extension HookSubscription: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, event, command, matchPattern, matchFlags, scope
    case timeoutSeconds, mode, cwd, env
    case allowRawOutput, allowRawInput, idleThresholdSeconds, disabled
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.event = try c.decode(HookEvent.self, forKey: .event)
    self.command = try c.decode(String.self, forKey: .command)
    self.matchPattern = try c.decodeIfPresent(String.self, forKey: .matchPattern)
    self.matchFlags = try c.decodeIfPresent(RegexFlags.self, forKey: .matchFlags) ?? []
    self.scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .anyPane
    self.timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 5
    self.mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .fireAndForget
    self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    self.env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    self.allowRawOutput = try c.decodeIfPresent(Bool.self, forKey: .allowRawOutput) ?? false
    self.allowRawInput = try c.decodeIfPresent(Bool.self, forKey: .allowRawInput) ?? false
    self.idleThresholdSeconds = try c.decodeIfPresent(Double.self, forKey: .idleThresholdSeconds)
    self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(event, forKey: .event)
    try c.encode(command, forKey: .command)
    try c.encodeIfPresent(matchPattern, forKey: .matchPattern)
    if !matchFlags.isEmpty { try c.encode(matchFlags, forKey: .matchFlags) }
    try c.encode(scope, forKey: .scope)
    try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
    try c.encode(mode, forKey: .mode)
    try c.encodeIfPresent(cwd, forKey: .cwd)
    if !env.isEmpty { try c.encode(env, forKey: .env) }
    if allowRawOutput { try c.encode(allowRawOutput, forKey: .allowRawOutput) }
    if allowRawInput { try c.encode(allowRawInput, forKey: .allowRawInput) }
    try c.encodeIfPresent(idleThresholdSeconds, forKey: .idleThresholdSeconds)
    if disabled { try c.encode(disabled, forKey: .disabled) }
  }
}

extension HookSubscription.Scope: Codable {
  private enum CodingKeys: String, CodingKey { case kind, value }
  private enum Kind: String, Codable {
    case anyPane, paneID, paneLabel, tabID, tabLabel, worktreeID, worktreePathGlob
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(Kind.self, forKey: .kind)
    switch kind {
    case .anyPane:
      self = .anyPane
    case .paneID:
      self = .paneID(try c.decode(PaneID.self, forKey: .value))
    case .paneLabel:
      self = .paneLabel(try c.decode(String.self, forKey: .value))
    case .tabID:
      self = .tabID(try c.decode(TabID.self, forKey: .value))
    case .tabLabel:
      self = .tabLabel(try c.decode(String.self, forKey: .value))
    case .worktreeID:
      self = .worktreeID(try c.decode(WorktreeID.self, forKey: .value))
    case .worktreePathGlob:
      self = .worktreePathGlob(try c.decode(String.self, forKey: .value))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .anyPane:
      try c.encode(Kind.anyPane, forKey: .kind)
    case .paneID(let id):
      try c.encode(Kind.paneID, forKey: .kind)
      try c.encode(id, forKey: .value)
    case .paneLabel(let label):
      try c.encode(Kind.paneLabel, forKey: .kind)
      try c.encode(label, forKey: .value)
    case .tabID(let id):
      try c.encode(Kind.tabID, forKey: .kind)
      try c.encode(id, forKey: .value)
    case .tabLabel(let label):
      try c.encode(Kind.tabLabel, forKey: .kind)
      try c.encode(label, forKey: .value)
    case .worktreeID(let id):
      try c.encode(Kind.worktreeID, forKey: .kind)
      try c.encode(id, forKey: .value)
    case .worktreePathGlob(let glob):
      try c.encode(Kind.worktreePathGlob, forKey: .kind)
      try c.encode(glob, forKey: .value)
    }
  }
}
