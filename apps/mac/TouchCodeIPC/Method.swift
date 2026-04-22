import Foundation

extension IPC {
  /// Every RPC method. Raw values are the on-wire method strings — lowercase
  /// dotted identifiers per the C4 design doc. Both client and server switch
  /// on this enum, never on the raw string.
  ///
  /// `skill.*` methods are intentionally absent (exec-plan 0003 DEC-5 defers
  /// the entire skill surface to exec-plan 0004).
  public enum Method: String, Codable, Hashable, Sendable, CaseIterable {
    // system
    case systemHello = "system.hello"
    case systemPing = "system.ping"
    case systemVersion = "system.version"
    case systemStatus = "system.status"
    case systemQuit = "system.quit"

    // editor — `editor.*` IPC surface. Handlers live in `EditorHandlers`;
    // `MethodRouter` dispatches each case post-M6b. C8a Phase 4c renamed
    // `editor.setDefault` → `editor.setGlobalDefault` and added
    // `editor.setProjectDefault` as a distinct verb for per-Project overrides.
    case editorDescribe = "editor.describe"
    case editorOpen = "editor.open"
    case editorSetGlobalDefault = "editor.setGlobalDefault"
    case editorSetProjectDefault = "editor.setProjectDefault"

    // hierarchy — reads
    case hierarchyListSpaces = "hierarchy.listSpaces"
    case hierarchyListProjects = "hierarchy.listProjects"
    case hierarchyListWorktrees = "hierarchy.listWorktrees"
    case hierarchyListTabs = "hierarchy.listTabs"
    case hierarchyListPanels = "hierarchy.listPanels"
    case hierarchyDescribeSpace = "hierarchy.describeSpace"
    case hierarchyDescribeProject = "hierarchy.describeProject"
    case hierarchyDescribeWorktree = "hierarchy.describeWorktree"
    case hierarchyDescribeTab = "hierarchy.describeTab"
    case hierarchyDescribePanel = "hierarchy.describePanel"
    case hierarchyResolveAlias = "hierarchy.resolveAlias"
    case hierarchyResolvePanelLabel = "hierarchy.resolvePanelLabel"
    case hierarchyResolveWorktreeGlob = "hierarchy.resolveWorktreeGlob"

    // hierarchy — mutations
    case hierarchyCreateSpace = "hierarchy.createSpace"
    case hierarchyRenameSpace = "hierarchy.renameSpace"
    case hierarchyRemoveSpace = "hierarchy.removeSpace"
    case hierarchyActivateSpace = "hierarchy.activateSpace"
    case hierarchyAddProject = "hierarchy.addProject"
    case hierarchyRemoveProject = "hierarchy.removeProject"
    case hierarchyRenameProject = "hierarchy.renameProject"
    case hierarchySetProjectEditor = "hierarchy.setProjectEditor"
    case hierarchyCreateWorktree = "hierarchy.createWorktree"
    case hierarchyRemoveWorktree = "hierarchy.removeWorktree"
    case hierarchyActivateWorktree = "hierarchy.activateWorktree"
    case hierarchyRenameWorktree = "hierarchy.renameWorktree"
    case hierarchyPruneWorktrees = "hierarchy.pruneWorktrees"
    case hierarchyCreateTab = "hierarchy.createTab"
    case hierarchyCloseTab = "hierarchy.closeTab"
    case hierarchyActivateTab = "hierarchy.activateTab"
    case hierarchyRenameTab = "hierarchy.renameTab"
    case hierarchyOpenPanel = "hierarchy.openPanel"
    case hierarchySplitPanel = "hierarchy.splitPanel"
    case hierarchyClosePanel = "hierarchy.closePanel"
    case hierarchyFocusPanel = "hierarchy.focusPanel"
    case hierarchyResizePanel = "hierarchy.resizePanel"
    case hierarchyZoomPanel = "hierarchy.zoomPanel"
    case hierarchyUnzoomPanel = "hierarchy.unzoomPanel"
    case hierarchySetPanelLabels = "hierarchy.setPanelLabels"

    // terminal
    case terminalSendInput = "terminal.sendInput"
    case terminalBroadcastInput = "terminal.broadcastInput"
    case terminalRetryPanel = "terminal.retryPanel"

    // hook
    case hookList = "hook.list"
    case hookInstall = "hook.install"
    case hookRemove = "hook.remove"
    case hookEnable = "hook.enable"
    case hookReload = "hook.reload"
    case hookTest = "hook.test"
    case hookFire = "hook.fire"
    case hookRecent = "hook.recent"
    case hookEvents = "hook.events"  // streaming
  }
}
