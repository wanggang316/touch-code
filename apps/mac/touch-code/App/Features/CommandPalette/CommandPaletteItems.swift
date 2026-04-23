import Foundation
import TouchCodeCore

/// Builds the list of `CommandPaletteItem` shown when the palette opens.
///
/// Called once per palette open (not per keystroke). The returned list is
/// filtered on every query change by `CommandPaletteFuzzyScorer`.
///
/// Items are emitted in three context bands:
///
/// 1. **Always**: app-level commands, Space switching / management.
/// 2. **When a Worktree is selected**: Git viewer toggle, editor-open
///    commands (one per installed `EditorDescriptor`), refresh, close,
///    reveal in Finder.
/// 3. **When a Panel is focused**: all `PanelActionRequest` and
///    `WindowActionRequest` cases that require a source panel. If no
///    panel is focused, these items are omitted rather than emitted with
///    a synthetic panel ID.
enum CommandPaletteItems {
  static func build(
    selection: HierarchySelection,
    catalog: Catalog,
    editorDescriptors: [EditorDescriptor] = []
  ) -> [CommandPaletteItem] {
    var items = appItems() + spaceItems(catalog: catalog)
    if let worktree = resolveWorktree(selection: selection, catalog: catalog) {
      items.append(contentsOf: worktreeItems(worktreeName: worktree.name))
      items.append(contentsOf: editorItems(worktreeName: worktree.name, descriptors: editorDescriptors))
    }
    if let focusedPanelID = resolveFocusedPanelID(selection: selection, catalog: catalog) {
      items.append(contentsOf: panelItems(focusedPanelID: focusedPanelID))
      items.append(contentsOf: windowItems(focusedPanelID: focusedPanelID))
    }
    return items
  }

  private static func appItems() -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "app.open-settings",
        title: "Open Settings",
        icon: "gearshape",
        shortcut: .command(","),
        kind: .openSettings
      ),
      CommandPaletteItem(
        id: "app.check-for-updates",
        title: "Check for Updates…",
        icon: "arrow.down.circle",
        kind: .checkForUpdates
      ),
      CommandPaletteItem(
        id: "app.quit",
        title: "Quit touch-code",
        icon: "power",
        shortcut: .command("Q"),
        hiddenWhenQueryEmpty: true,
        kind: .quit
      ),
    ]
  }

  private static func spaceItems(catalog: Catalog) -> [CommandPaletteItem] {
    var items: [CommandPaletteItem] = [
      CommandPaletteItem(
        id: "space.manage",
        title: "Manage Spaces…",
        icon: "slider.horizontal.3",
        kind: .openSpaceManager
      )
    ]
    for (index, space) in catalog.spaces.enumerated() {
      let isActive = catalog.selectedSpaceID == space.id
      let indexChord: KeyEquivalentDescriptor? =
        index < 9 ? .command("\(index + 1)") : nil
      items.append(
        CommandPaletteItem(
          id: "space.select.\(space.id.raw.uuidString)",
          title: "Switch to Space: \(space.name)",
          subtitle: isActive ? "Currently active" : nil,
          icon: "square.stack",
          shortcut: indexChord,
          priorityTier: isActive ? 110 : 100,
          kind: .selectSpace(space.id)
        )
      )
    }
    return items
  }

  private static func resolveWorktree(
    selection: HierarchySelection,
    catalog: Catalog
  ) -> Worktree? {
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID
    else { return nil }
    return catalog.spaces.first(where: { $0.id == spaceID })?
      .projects.first(where: { $0.id == projectID })?
      .worktrees.first(where: { $0.id == worktreeID })
  }

  private static func worktreeItems(worktreeName: String) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "git.toggle-viewer",
        title: "Toggle Git Viewer",
        subtitle: worktreeName,
        icon: "doc.text.magnifyingglass",
        shortcut: .command("G", shift: true),
        kind: .toggleGitViewer
      ),
      CommandPaletteItem(
        id: "editor.reveal-in-finder",
        title: "Reveal in Finder",
        subtitle: worktreeName,
        icon: "folder",
        kind: .revealCurrentWorktreeInFinder
      ),
      CommandPaletteItem(
        id: "worktree.refresh",
        title: "Refresh Worktree",
        subtitle: worktreeName,
        icon: "arrow.clockwise",
        kind: .refreshCurrentWorktree
      ),
      CommandPaletteItem(
        id: "worktree.close",
        title: "Close Worktree",
        subtitle: worktreeName,
        icon: "xmark.square",
        hiddenWhenQueryEmpty: true,
        kind: .closeCurrentWorktree
      ),
    ]
  }

  private static func editorItems(
    worktreeName: String,
    descriptors: [EditorDescriptor]
  ) -> [CommandPaletteItem] {
    var items: [CommandPaletteItem] = [
      CommandPaletteItem(
        id: "editor.open-default",
        title: "Open in Default Editor",
        subtitle: worktreeName,
        icon: "arrow.up.forward.app",
        shortcut: .command("E"),
        kind: .openCurrentWorktreeInDefaultEditor
      )
    ]
    for descriptor in descriptors {
      items.append(
        CommandPaletteItem(
          id: "editor.open.\(descriptor.id)",
          title: "Open in \(descriptor.displayName)",
          subtitle: worktreeName,
          icon: "arrow.up.forward.app",
          kind: .openCurrentWorktreeIn(descriptor.id)
        )
      )
    }
    return items
  }

  /// Walks the catalog from the selection down to a representative
  /// panel for the active tab. The catalog doesn't track "focused panel"
  /// explicitly — the ghostty runtime owns that state — but Window- and
  /// Panel-scoped palette actions need *a* PanelID to target the right
  /// window. We use the first leaf of the selected tab's split tree,
  /// which is guaranteed to map to the same NSWindow as the focused
  /// panel.
  static func resolveFocusedPanelID(
    selection: HierarchySelection,
    catalog: Catalog
  ) -> PanelID? {
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let space = catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let selectedTabID = worktree.selectedTabID,
      let tab = worktree.tabs.first(where: { $0.id == selectedTabID })
    else { return nil }
    return tab.splitTree.leaves().first
  }

  // MARK: - Private builders

  private static func panelItems(focusedPanelID: PanelID) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "panel.new-tab",
        title: "New Tab",
        icon: "plus.rectangle.on.rectangle",
        kind: .panelAction(.newTab)
      ),
      CommandPaletteItem(
        id: "panel.split.right",
        title: "Split Right",
        icon: "rectangle.split.2x1",
        kind: .panelAction(.newSplit(direction: .right))
      ),
      CommandPaletteItem(
        id: "panel.split.down",
        title: "Split Down",
        icon: "rectangle.split.1x2",
        kind: .panelAction(.newSplit(direction: .down))
      ),
      CommandPaletteItem(
        id: "panel.focus.left",
        title: "Focus Left Split",
        icon: "arrow.left",
        kind: .panelAction(.gotoSplit(direction: .left))
      ),
      CommandPaletteItem(
        id: "panel.focus.right",
        title: "Focus Right Split",
        icon: "arrow.right",
        kind: .panelAction(.gotoSplit(direction: .right))
      ),
      CommandPaletteItem(
        id: "panel.focus.up",
        title: "Focus Split Above",
        icon: "arrow.up",
        kind: .panelAction(.gotoSplit(direction: .up))
      ),
      CommandPaletteItem(
        id: "panel.focus.down",
        title: "Focus Split Below",
        icon: "arrow.down",
        kind: .panelAction(.gotoSplit(direction: .down))
      ),
      CommandPaletteItem(
        id: "panel.equalize",
        title: "Equalize Splits",
        icon: "rectangle.split.3x1",
        kind: .panelAction(.equalizeSplits)
      ),
      CommandPaletteItem(
        id: "panel.toggle-zoom",
        title: "Toggle Split Zoom",
        icon: "plus.magnifyingglass",
        kind: .panelAction(.toggleSplitZoom)
      ),
      CommandPaletteItem(
        id: "panel.close-tab",
        title: "Close Tab",
        icon: "xmark.circle",
        hiddenWhenQueryEmpty: true,
        kind: .panelAction(.closeTab(mode: .this))
      ),
    ]
  }

  private static func windowItems(focusedPanelID: PanelID) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "window.new",
        title: "New Window",
        icon: "macwindow.badge.plus",
        kind: .windowAction(.new(from: focusedPanelID))
      ),
      CommandPaletteItem(
        id: "window.close",
        title: "Close Window",
        icon: "xmark",
        hiddenWhenQueryEmpty: true,
        kind: .windowAction(.close(from: focusedPanelID))
      ),
      CommandPaletteItem(
        id: "window.toggle-fullscreen",
        title: "Toggle Fullscreen",
        icon: "arrow.up.left.and.arrow.down.right",
        kind: .windowAction(.toggleFullscreen(from: focusedPanelID))
      ),
      CommandPaletteItem(
        id: "window.toggle-tab-overview",
        title: "Show Tab Overview",
        icon: "square.grid.2x2",
        kind: .windowAction(.toggleTabOverview(from: focusedPanelID))
      ),
    ]
  }
}
