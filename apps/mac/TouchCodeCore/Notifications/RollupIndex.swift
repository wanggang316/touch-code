import Foundation

/// Per-level unread roll-up over the inbox + current focus state.
///
/// Each unread entry contributes to **exactly one** level: the deepest
/// hierarchy ancestor that is currently *hidden* from the user. If the
/// user can already see deeper into a level, the indicator at the higher
/// level is suppressed and shown only at the deepest still-hidden
/// ancestor.
///
/// Per-level visuals (boolean):
/// - L4 Project   — small unread dot to the right of the project name
/// - L3 Worktree  — leading row icon swaps to a bell glyph
/// - L2 Tab       — small unread dot prefixed before the tab title
/// - L1 Pane      — 2 px coloured top line; amber for waitingForInput
///                  (overrides green on conflict), green for taskFinished
///
/// `globalUnreadCount` is the total ungrouped unread count. Only the
/// status-bar bell badge and the Dock tile badge consume it.
public nonisolated struct RollupIndex: Equatable, Sendable {
  public let unreadProjects: Set<ProjectID>
  public let unreadWorktrees: Set<WorktreeID>
  public let unreadTabs: Set<TabID>
  public let paneIndicator: [PaneID: PaneIndicator]
  public let globalUnreadCount: Int

  public init(
    unreadProjects: Set<ProjectID> = [],
    unreadWorktrees: Set<WorktreeID> = [],
    unreadTabs: Set<TabID> = [],
    paneIndicator: [PaneID: PaneIndicator] = [:],
    globalUnreadCount: Int = 0
  ) {
    self.unreadProjects = unreadProjects
    self.unreadWorktrees = unreadWorktrees
    self.unreadTabs = unreadTabs
    self.paneIndicator = paneIndicator
    self.globalUnreadCount = globalUnreadCount
  }

  public static let empty = RollupIndex()

  /// Walk every unread entry, decide which level emits its indicator
  /// per the visibility rules in the design doc, and accumulate.
  public static func compute(
    unread: [InboxEntry],
    focus: RollupFocusState
  ) -> RollupIndex {
    var unreadProjects: Set<ProjectID> = []
    var unreadWorktrees: Set<WorktreeID> = []
    var unreadTabs: Set<TabID> = []
    var paneIndicator: [PaneID: PaneIndicator] = [:]

    for entry in unread {
      let level = deepestHiddenLevel(for: entry.source, focus: focus)
      switch level {
      case .project:
        unreadProjects.insert(entry.source.projectID)
      case .worktree:
        unreadWorktrees.insert(entry.source.worktreeID)
      case .tab:
        unreadTabs.insert(entry.source.tabID)
      case .pane:
        // Amber (waitingForInput) wins over green (taskFinished) on
        // pane-level conflict — the user being summoned trumps a
        // background completion.
        let incoming: PaneIndicator =
          entry.kind == .waitingForInput ? .waitingForInput : .taskFinished
        if let existing = paneIndicator[entry.source.paneID] {
          paneIndicator[entry.source.paneID] = priorityWinner(existing, incoming)
        } else {
          paneIndicator[entry.source.paneID] = incoming
        }
      }
    }

    return RollupIndex(
      unreadProjects: unreadProjects,
      unreadWorktrees: unreadWorktrees,
      unreadTabs: unreadTabs,
      paneIndicator: paneIndicator,
      globalUnreadCount: unread.count
    )
  }

  // MARK: - Visibility logic

  enum Level { case project, worktree, tab, pane }

  /// Decide which level renders the indicator for one source path. The
  /// rule is "deepest hidden ancestor": walk down from project, stop at
  /// the first level the user cannot see into.
  private static func deepestHiddenLevel(
    for source: InboxEntry.SourcePath,
    focus: RollupFocusState
  ) -> Level {
    if !focus.expandedProjectIDs.contains(source.projectID) {
      return .project
    }
    let projectIsActive = focus.activeProjectID == source.projectID
    let worktreeIsActive = projectIsActive && focus.activeWorktreeID == source.worktreeID
    if !worktreeIsActive {
      return .worktree
    }
    let tabIsActive = focus.activeTabID == source.tabID
    if !tabIsActive {
      return .tab
    }
    let paneIsFocused = focus.focusedPaneID == source.paneID
    if !paneIsFocused {
      return .pane
    }
    // The user is looking directly at the source pane — surface as Pane
    // anyway so the (transient) indicator is visible until R1 marks it
    // read on next focus change.
    return .pane
  }

  private static func priorityWinner(
    _ a: PaneIndicator,
    _ b: PaneIndicator
  ) -> PaneIndicator {
    a == .waitingForInput || b == .waitingForInput ? .waitingForInput : .taskFinished
  }
}

/// L1 pane top-line colour selector. Mirrors `InboxEntry.Kind` but
/// excludes the "no indicator" case from the type — a pane simply does
/// not appear in `RollupIndex.paneIndicator` when it has no unread
/// entries to surface at the pane level.
public nonisolated enum PaneIndicator: String, Codable, Sendable, Equatable {
  case taskFinished
  case waitingForInput
}

/// Snapshot of the data the user can currently see in the sidebar /
/// tab-bar / pane chrome. Drives `RollupIndex.compute`'s visibility rule.
public nonisolated struct RollupFocusState: Equatable, Sendable {
  public let focusedPaneID: PaneID?
  public let activeTabID: TabID?
  public let activeWorktreeID: WorktreeID?
  public let activeProjectID: ProjectID?
  /// Projects whose disclosure row is currently expanded in the sidebar.
  /// Worktrees / tabs / panes inside a collapsed project are not visible
  /// to the user, so unread events for them roll up to project level.
  public let expandedProjectIDs: Set<ProjectID>

  public init(
    focusedPaneID: PaneID? = nil,
    activeTabID: TabID? = nil,
    activeWorktreeID: WorktreeID? = nil,
    activeProjectID: ProjectID? = nil,
    expandedProjectIDs: Set<ProjectID> = []
  ) {
    self.focusedPaneID = focusedPaneID
    self.activeTabID = activeTabID
    self.activeWorktreeID = activeWorktreeID
    self.activeProjectID = activeProjectID
    self.expandedProjectIDs = expandedProjectIDs
  }
}
