import Foundation

/// Lifecycle events the app emits and user hook handlers subscribe to.
///
/// Event names are lowercase-dotted strings. The string raw values are the
/// canonical on-wire identity; Swift code switches on the enum, never the
/// string. Adding a case is additive for forward-compat; removing a case
/// requires a schema bump on `HookConfig.version`.
public nonisolated enum HookEvent: String, Codable, Hashable, Sendable, CaseIterable {
  case paneCreated = "pane.created"
  case paneReady = "pane.ready"
  case paneInput = "pane.input"
  case paneOutput = "pane.output"
  case paneOutputMatch = "pane.outputMatch"
  case paneIdle = "pane.idle"
  case paneExited = "pane.exited"
  case paneCrashed = "pane.crashed"
  case tabActivated = "tab.activated"
  case tabDeactivated = "tab.deactivated"
  case tabAutoClosed = "tab.autoClosed"
  case worktreeActivated = "worktree.activated"
  case worktreeDeactivated = "worktree.deactivated"
  case worktreeCreated = "worktree.created"
  case worktreeRemoved = "worktree.removed"

  /// The scope anchor required for this event. `pane.*` events always carry
  /// a `pane` ref (plus its ancestors); `tab.*` always carry `tab`; etc.
  public var scope: HookScope {
    switch self {
    case .paneCreated, .paneReady, .paneInput, .paneOutput, .paneOutputMatch,
      .paneIdle, .paneExited, .paneCrashed:
      return .pane
    case .tabActivated, .tabDeactivated, .tabAutoClosed:
      return .tab
    case .worktreeActivated, .worktreeDeactivated, .worktreeCreated, .worktreeRemoved:
      return .worktree
    }
  }
}

public nonisolated enum HookScope: String, Codable, Hashable, Sendable {
  case pane, tab, worktree, space
}
