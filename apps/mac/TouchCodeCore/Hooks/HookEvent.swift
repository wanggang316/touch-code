import Foundation

/// Lifecycle events the app emits and user hook handlers subscribe to.
///
/// Event names are lowercase-dotted strings. The string raw values are the
/// canonical on-wire identity; Swift code switches on the enum, never the
/// string. Adding a case is additive for forward-compat; removing a case
/// requires a schema bump on `HookConfig.version`.
public nonisolated enum HookEvent: String, Codable, Hashable, Sendable, CaseIterable {
  case panelCreated     = "panel.created"
  case panelReady       = "panel.ready"
  case panelInput       = "panel.input"
  case panelOutput      = "panel.output"
  case panelOutputMatch = "panel.outputMatch"
  case panelIdle        = "panel.idle"
  case panelExited      = "panel.exited"
  case panelCrashed     = "panel.crashed"
  case tabActivated     = "tab.activated"
  case tabDeactivated   = "tab.deactivated"
  case tabAutoClosed    = "tab.autoClosed"
  case worktreeActivated   = "worktree.activated"
  case worktreeDeactivated = "worktree.deactivated"
  case worktreeCreated     = "worktree.created"
  case worktreeRemoved     = "worktree.removed"

  /// The scope anchor required for this event. `panel.*` events always carry
  /// a `panel` ref (plus its ancestors); `tab.*` always carry `tab`; etc.
  public var scope: HookScope {
    switch self {
    case .panelCreated, .panelReady, .panelInput, .panelOutput, .panelOutputMatch,
         .panelIdle, .panelExited, .panelCrashed:
      return .panel
    case .tabActivated, .tabDeactivated, .tabAutoClosed:
      return .tab
    case .worktreeActivated, .worktreeDeactivated, .worktreeCreated, .worktreeRemoved:
      return .worktree
    }
  }
}

public nonisolated enum HookScope: String, Codable, Hashable, Sendable {
  case panel, tab, worktree, space
}
