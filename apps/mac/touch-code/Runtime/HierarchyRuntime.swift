import Foundation
import TouchCodeCore

protocol HierarchyRuntime: AnyObject {
  func ensureSurface(for panel: Panel, in worktree: Worktree) throws
  func closeSurface(for panelID: PanelID)
}
