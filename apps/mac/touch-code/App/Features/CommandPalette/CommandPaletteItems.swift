import Foundation
import TouchCodeCore

/// Builds the list of `CommandPaletteItem` shown when the palette opens.
///
/// **M2 scope**: returns three global commands unconditionally so the
/// vertical-slice pipeline (⌘P → type → Enter → action dispatched) can be
/// exercised end-to-end. The full context-sensitive builder — per-Space /
/// per-Worktree / per-Editor items, Panel + Window actions — lands in M5
/// and extends this single function; call sites do not change.
enum CommandPaletteItems {
  static func build(
    selection: HierarchySelection,
    catalog: Catalog
  ) -> [CommandPaletteItem] {
    [
      CommandPaletteItem(
        id: "app.open-settings",
        title: "Open Settings",
        icon: "gearshape",
        shortcut: .command(","),
        kind: .openSettings
      ),
      CommandPaletteItem(
        id: "git.toggle-viewer",
        title: "Toggle Git Viewer",
        icon: "doc.text.magnifyingglass",
        shortcut: .command("G", shift: true),
        kind: .toggleGitViewer
      ),
      CommandPaletteItem(
        id: "app.check-for-updates",
        title: "Check for Updates…",
        icon: "arrow.down.circle",
        kind: .checkForUpdates
      ),
    ]
  }
}
