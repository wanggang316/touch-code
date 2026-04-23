import Foundation
import TouchCodeCore

/// One row in the Command Palette.
///
/// Items are rebuilt from live state on every palette open; `id` is the
/// only field that persists across rebuilds (used as the recency map key),
/// so it must be stable across launches for parameterized Kinds — e.g.
/// `"worktree.select.<uuid>"` not `"worktree.select.<index>"`.
struct CommandPaletteItem: Equatable, Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let icon: String
  let shortcut: KeyEquivalentDescriptor?
  let priorityTier: Int
  /// When true, the item is excluded from the empty-query list. Reserved
  /// for sharp-edge commands (e.g. "Close Current Worktree") that should
  /// not surface by accident the moment the user opens the palette.
  let hiddenWhenQueryEmpty: Bool
  let kind: Kind

  init(
    id: String,
    title: String,
    subtitle: String? = nil,
    icon: String,
    shortcut: KeyEquivalentDescriptor? = nil,
    priorityTier: Int = 100,
    hiddenWhenQueryEmpty: Bool = false,
    kind: Kind
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.shortcut = shortcut
    self.priorityTier = priorityTier
    self.hiddenWhenQueryEmpty = hiddenWhenQueryEmpty
    self.kind = kind
  }

  enum Kind: Equatable {
    // App
    case openSettings
    case checkForUpdates
    case quit

    // Space
    case selectSpace(SpaceID)
    case openSpaceManager
    case switchToSpaceAtIndex(Int)

    // Worktree
    case selectWorktree(SpaceID, ProjectID, WorktreeID)
    case closeCurrentWorktree
    case refreshCurrentWorktree
    case toggleGitViewer

    // Editor
    case openCurrentWorktreeInDefaultEditor
    case openCurrentWorktreeIn(EditorID)
    case revealCurrentWorktreeInFinder

    // Pane / Window (thin wrappers over the existing request enums)
    case paneAction(PaneActionRequest)
    case windowAction(WindowActionRequest)
  }
}
