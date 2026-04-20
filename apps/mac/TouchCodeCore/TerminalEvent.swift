import Foundation

/// Path-scoped identifier for `TerminalEvent.hierarchyMutated`. Lets TCA
/// consumers invalidate only the affected subtree instead of refreshing the
/// whole catalog.
public nonisolated enum HierarchyMutationScope: Sendable, Equatable {
  case catalog
  case space(SpaceID)
  case project(SpaceID, ProjectID)
  case worktree(SpaceID, ProjectID, WorktreeID)
  case tab(SpaceID, ProjectID, WorktreeID, TabID)
  case panel(SpaceID, ProjectID, WorktreeID, TabID, PanelID)
  case selection
}

public nonisolated enum TabAutoCloseCause: Sendable, Equatable {
  case crashLoop(count: Int, window: TimeInterval)
  case other(reason: String)
}

public nonisolated enum TerminalEvent: Sendable {
  case panelCreated(PanelID, TabID)
  case panelReady(PanelID)
  /// Coalesced bytes batch. Note: `data` may split a UTF-8 codepoint at the
  /// 16 KB buffer boundary — consumers that decode text (scrollback viewer,
  /// C3 hook matchers) must buffer across batches per panel.
  case panelOutput(PanelID, Data)
  case panelIdle(PanelID, duration: TimeInterval)
  /// Clean child exit. `code` is the exit status; `signal` is non-nil when
  /// the child was terminated by a signal (SIGKILL / SIGTERM / etc.) and
  /// exists to disambiguate from a normal non-zero return.
  case panelExited(PanelID, code: Int32, signal: Int32?)
  case panelCrashed(PanelID, reason: String)
  /// Panel was forcibly closed because its enclosing Tab was auto-closed
  /// (e.g. by crash-loop). Distinct from `panelExited(code: 0)` because the
  /// child did not exit cleanly — persistence and hook consumers should not
  /// treat this as a clean exit.
  case panelClosedByTab(PanelID, cause: TabAutoCloseCause)
  case tabActivated(TabID)
  case tabAutoClosed(TabID, cause: TabAutoCloseCause)
  case worktreeActivated(WorktreeID)
  case hierarchyMutated(HierarchyMutationScope)
}
