import Foundation
import TouchCodeCore

protocol HierarchyRuntime: AnyObject {
  func ensureSurface(for panel: Panel, in worktree: Worktree) throws
  func closeSurface(for panelID: PanelID)
  /// Reports whether a live terminal surface is currently registered for
  /// the given panel. Used by force-remove to size the
  /// "terminate N running processes" confirmation (spec W-Q3).
  /// Default `false` keeps legacy consumers working without changes.
  func hasSurface(for panelID: PanelID) -> Bool
}

extension HierarchyRuntime {
  func hasSurface(for panelID: PanelID) -> Bool { false }
}
