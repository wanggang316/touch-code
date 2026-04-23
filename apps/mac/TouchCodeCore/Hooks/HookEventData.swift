import Foundation

/// Per-event payload. Hand-rolled `Codable` with a `"kind"` discriminator that
/// mirrors the outer envelope's `event` field; decoding validates the two
/// agree.
public nonisolated enum HookEventData: Equatable, Sendable {
  case paneCreated(createdVia: String)
  case paneReady(pid: Int32?, shell: String)
  case paneInput(text: String, inputBytes: Int)
  case paneOutput(output: Data, outputBytes: Int)
  case paneOutputMatch(match: String, matchedRange: HookMatchRange, output: Data, outputBytes: Int)
  case paneIdle(idleSeconds: Double, sinceLastOutput: Double, sinceLastInput: Double)
  case paneExited(exitCode: Int32)
  case paneCrashed(reason: String)
  case tabActivated(previousTabID: TabID?)
  case tabDeactivated(nextTabID: TabID?)
  case tabAutoClosed(reason: String, crashCount: Int, windowSeconds: Int)
  case worktreeActivated(previousWorktreeID: WorktreeID?)
  case worktreeDeactivated(nextWorktreeID: WorktreeID?)
  case worktreeCreated(branch: String?, gitExit: Int32?)
  case worktreeRemoved(keepDirectory: Bool)

  public var kind: HookEvent {
    switch self {
    case .paneCreated: return .paneCreated
    case .paneReady: return .paneReady
    case .paneInput: return .paneInput
    case .paneOutput: return .paneOutput
    case .paneOutputMatch: return .paneOutputMatch
    case .paneIdle: return .paneIdle
    case .paneExited: return .paneExited
    case .paneCrashed: return .paneCrashed
    case .tabActivated: return .tabActivated
    case .tabDeactivated: return .tabDeactivated
    case .tabAutoClosed: return .tabAutoClosed
    case .worktreeActivated: return .worktreeActivated
    case .worktreeDeactivated: return .worktreeDeactivated
    case .worktreeCreated: return .worktreeCreated
    case .worktreeRemoved: return .worktreeRemoved
    }
  }
}

extension HookEventData: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case createdVia
    case pid
    case shell
    case text
    case inputBytes
    case output
    case outputBytes
    case match
    case matchedRange
    case idleSeconds
    case sinceLastOutput
    case sinceLastInput
    case exitCode
    case reason
    case previousTabID
    case nextTabID
    case crashCount
    case windowSeconds
    case previousWorktreeID
    case nextWorktreeID
    case branch
    case gitExit
    case keepDirectory
  }

  public enum DecodingIssue: Error, Equatable {
    case unknownKind(String)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(HookEvent.self, forKey: .kind)
    switch kind {
    case .paneCreated:
      let createdVia = try container.decode(String.self, forKey: .createdVia)
      self = .paneCreated(createdVia: createdVia)
    case .paneReady:
      let pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
      let shell = try container.decode(String.self, forKey: .shell)
      self = .paneReady(pid: pid, shell: shell)
    case .paneInput:
      let text = try container.decode(String.self, forKey: .text)
      let inputBytes = try container.decode(Int.self, forKey: .inputBytes)
      self = .paneInput(text: text, inputBytes: inputBytes)
    case .paneOutput:
      let output = try container.decode(Data.self, forKey: .output)
      let outputBytes = try container.decode(Int.self, forKey: .outputBytes)
      self = .paneOutput(output: output, outputBytes: outputBytes)
    case .paneOutputMatch:
      let match = try container.decode(String.self, forKey: .match)
      let range = try container.decode(HookMatchRange.self, forKey: .matchedRange)
      let output = try container.decode(Data.self, forKey: .output)
      let outputBytes = try container.decode(Int.self, forKey: .outputBytes)
      self = .paneOutputMatch(match: match, matchedRange: range, output: output, outputBytes: outputBytes)
    case .paneIdle:
      let idleSeconds = try container.decode(Double.self, forKey: .idleSeconds)
      let sinceOut = try container.decode(Double.self, forKey: .sinceLastOutput)
      let sinceIn = try container.decode(Double.self, forKey: .sinceLastInput)
      self = .paneIdle(idleSeconds: idleSeconds, sinceLastOutput: sinceOut, sinceLastInput: sinceIn)
    case .paneExited:
      let exitCode = try container.decode(Int32.self, forKey: .exitCode)
      self = .paneExited(exitCode: exitCode)
    case .paneCrashed:
      let reason = try container.decode(String.self, forKey: .reason)
      self = .paneCrashed(reason: reason)
    case .tabActivated:
      let prev = try container.decodeIfPresent(TabID.self, forKey: .previousTabID)
      self = .tabActivated(previousTabID: prev)
    case .tabDeactivated:
      let next = try container.decodeIfPresent(TabID.self, forKey: .nextTabID)
      self = .tabDeactivated(nextTabID: next)
    case .tabAutoClosed:
      let reason = try container.decode(String.self, forKey: .reason)
      let count = try container.decode(Int.self, forKey: .crashCount)
      let windowSeconds = try container.decode(Int.self, forKey: .windowSeconds)
      self = .tabAutoClosed(reason: reason, crashCount: count, windowSeconds: windowSeconds)
    case .worktreeActivated:
      let prev = try container.decodeIfPresent(WorktreeID.self, forKey: .previousWorktreeID)
      self = .worktreeActivated(previousWorktreeID: prev)
    case .worktreeDeactivated:
      let next = try container.decodeIfPresent(WorktreeID.self, forKey: .nextWorktreeID)
      self = .worktreeDeactivated(nextWorktreeID: next)
    case .worktreeCreated:
      let branch = try container.decodeIfPresent(String.self, forKey: .branch)
      let gitExit = try container.decodeIfPresent(Int32.self, forKey: .gitExit)
      self = .worktreeCreated(branch: branch, gitExit: gitExit)
    case .worktreeRemoved:
      let keep = try container.decode(Bool.self, forKey: .keepDirectory)
      self = .worktreeRemoved(keepDirectory: keep)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .paneCreated(let via):
      try container.encode(via, forKey: .createdVia)
    case .paneReady(let pid, let shell):
      try container.encodeIfPresent(pid, forKey: .pid)
      try container.encode(shell, forKey: .shell)
    case .paneInput(let text, let inputBytes):
      try container.encode(text, forKey: .text)
      try container.encode(inputBytes, forKey: .inputBytes)
    case .paneOutput(let output, let outputBytes):
      try container.encode(output, forKey: .output)
      try container.encode(outputBytes, forKey: .outputBytes)
    case .paneOutputMatch(let match, let range, let output, let outputBytes):
      try container.encode(match, forKey: .match)
      try container.encode(range, forKey: .matchedRange)
      try container.encode(output, forKey: .output)
      try container.encode(outputBytes, forKey: .outputBytes)
    case .paneIdle(let idle, let sinceOut, let sinceIn):
      try container.encode(idle, forKey: .idleSeconds)
      try container.encode(sinceOut, forKey: .sinceLastOutput)
      try container.encode(sinceIn, forKey: .sinceLastInput)
    case .paneExited(let code):
      try container.encode(code, forKey: .exitCode)
    case .paneCrashed(let reason):
      try container.encode(reason, forKey: .reason)
    case .tabActivated(let prev):
      try container.encodeIfPresent(prev, forKey: .previousTabID)
    case .tabDeactivated(let next):
      try container.encodeIfPresent(next, forKey: .nextTabID)
    case .tabAutoClosed(let reason, let count, let windowSeconds):
      try container.encode(reason, forKey: .reason)
      try container.encode(count, forKey: .crashCount)
      try container.encode(windowSeconds, forKey: .windowSeconds)
    case .worktreeActivated(let prev):
      try container.encodeIfPresent(prev, forKey: .previousWorktreeID)
    case .worktreeDeactivated(let next):
      try container.encodeIfPresent(next, forKey: .nextWorktreeID)
    case .worktreeCreated(let branch, let gitExit):
      try container.encodeIfPresent(branch, forKey: .branch)
      try container.encodeIfPresent(gitExit, forKey: .gitExit)
    case .worktreeRemoved(let keep):
      try container.encode(keep, forKey: .keepDirectory)
    }
  }
}
