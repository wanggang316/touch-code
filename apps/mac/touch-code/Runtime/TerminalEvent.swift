import Foundation
import TouchCodeCore

enum TerminalEvent: Sendable {
  case panelCreated(PanelID, TabID)
  case panelReady(PanelID)
  case panelOutput(PanelID, Data)
  case panelIdle(PanelID, duration: TimeInterval)
  case panelExited(PanelID, code: Int32)
  case panelCrashed(PanelID, reason: String)
  case tabActivated(TabID)
  case tabAutoClosed(TabID, reason: String)
  case worktreeActivated(WorktreeID)
  case hierarchyMutated
}
