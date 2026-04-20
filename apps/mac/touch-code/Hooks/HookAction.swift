import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Stdout DSL a hook handler may emit to request follow-up app actions.
///
/// Moved to the in-app Hooks subfolder (exec-plan 0003 DEC-13) because the
/// `panelBroadcast` variant uses `IPC.BroadcastScope` directly (DEC-12),
/// which would close a dependency cycle if `HookAction` lived in
/// `TouchCodeCore` (since `TouchCodeIPC` imports `TouchCodeCore`).
///
/// The 10 variants are pinned by the C3 design doc D5.
public nonisolated enum HookAction: Equatable, Sendable {
  case panelSend(PanelID, text: String, raw: Bool)
  case panelBroadcast(scope: IPC.BroadcastScope, text: String, raw: Bool)
  case panelOpen(in: WorktreeID, tab: TabID?, workingDirectory: String?, initialCommand: String?)
  case panelClose(PanelID)
  case tabActivate(TabID)
  case tabCreate(in: WorktreeID, name: String?)
  case worktreeActivate(WorktreeID)
  case notify(title: String, body: String?, panelID: PanelID?)
  case log(level: String, message: String)
  case setPanelLabels(PanelID, [String])

  public var kind: String {
    switch self {
    case .panelSend: return "panel.send"
    case .panelBroadcast: return "panel.broadcast"
    case .panelOpen: return "panel.open"
    case .panelClose: return "panel.close"
    case .tabActivate: return "tab.activate"
    case .tabCreate: return "tab.create"
    case .worktreeActivate: return "worktree.activate"
    case .notify: return "notify"
    case .log: return "log"
    case .setPanelLabels: return "panel.setLabels"
    }
  }
}

nonisolated extension HookAction: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case panelID, text, raw
    case scope
    case worktreeID, tabID, workingDirectory, initialCommand
    case name
    case title, body
    case level, message
    case labels
  }

  public enum DecodingIssue: Error, Equatable {
    case unknownKind(String)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(String.self, forKey: .kind)
    switch kind {
    case "panel.send":
      let id = try c.decode(PanelID.self, forKey: .panelID)
      let text = try c.decode(String.self, forKey: .text)
      let raw = try c.decodeIfPresent(Bool.self, forKey: .raw) ?? false
      self = .panelSend(id, text: text, raw: raw)
    case "panel.broadcast":
      let scope = try c.decode(IPC.BroadcastScope.self, forKey: .scope)
      let text = try c.decode(String.self, forKey: .text)
      let raw = try c.decodeIfPresent(Bool.self, forKey: .raw) ?? false
      self = .panelBroadcast(scope: scope, text: text, raw: raw)
    case "panel.open":
      let wt = try c.decode(WorktreeID.self, forKey: .worktreeID)
      let tab = try c.decodeIfPresent(TabID.self, forKey: .tabID)
      let wd = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
      let cmd = try c.decodeIfPresent(String.self, forKey: .initialCommand)
      self = .panelOpen(in: wt, tab: tab, workingDirectory: wd, initialCommand: cmd)
    case "panel.close":
      self = .panelClose(try c.decode(PanelID.self, forKey: .panelID))
    case "tab.activate":
      self = .tabActivate(try c.decode(TabID.self, forKey: .tabID))
    case "tab.create":
      let wt = try c.decode(WorktreeID.self, forKey: .worktreeID)
      let name = try c.decodeIfPresent(String.self, forKey: .name)
      self = .tabCreate(in: wt, name: name)
    case "worktree.activate":
      self = .worktreeActivate(try c.decode(WorktreeID.self, forKey: .worktreeID))
    case "notify":
      let title = try c.decode(String.self, forKey: .title)
      let body = try c.decodeIfPresent(String.self, forKey: .body)
      let pid = try c.decodeIfPresent(PanelID.self, forKey: .panelID)
      self = .notify(title: title, body: body, panelID: pid)
    case "log":
      let level = try c.decode(String.self, forKey: .level)
      let message = try c.decode(String.self, forKey: .message)
      self = .log(level: level, message: message)
    case "panel.setLabels":
      let id = try c.decode(PanelID.self, forKey: .panelID)
      let labels = try c.decode([String].self, forKey: .labels)
      self = .setPanelLabels(id, labels)
    default:
      throw DecodingIssue.unknownKind(kind)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    switch self {
    case .panelSend(let id, let text, let raw):
      try c.encode(id, forKey: .panelID)
      try c.encode(text, forKey: .text)
      if raw { try c.encode(raw, forKey: .raw) }
    case .panelBroadcast(let scope, let text, let raw):
      try c.encode(scope, forKey: .scope)
      try c.encode(text, forKey: .text)
      if raw { try c.encode(raw, forKey: .raw) }
    case .panelOpen(let wt, let tab, let wd, let cmd):
      try c.encode(wt, forKey: .worktreeID)
      try c.encodeIfPresent(tab, forKey: .tabID)
      try c.encodeIfPresent(wd, forKey: .workingDirectory)
      try c.encodeIfPresent(cmd, forKey: .initialCommand)
    case .panelClose(let id):
      try c.encode(id, forKey: .panelID)
    case .tabActivate(let id):
      try c.encode(id, forKey: .tabID)
    case .tabCreate(let wt, let name):
      try c.encode(wt, forKey: .worktreeID)
      try c.encodeIfPresent(name, forKey: .name)
    case .worktreeActivate(let id):
      try c.encode(id, forKey: .worktreeID)
    case .notify(let title, let body, let pid):
      try c.encode(title, forKey: .title)
      try c.encodeIfPresent(body, forKey: .body)
      try c.encodeIfPresent(pid, forKey: .panelID)
    case .log(let level, let message):
      try c.encode(level, forKey: .level)
      try c.encode(message, forKey: .message)
    case .setPanelLabels(let id, let labels):
      try c.encode(id, forKey: .panelID)
      try c.encode(labels, forKey: .labels)
    }
  }
}
