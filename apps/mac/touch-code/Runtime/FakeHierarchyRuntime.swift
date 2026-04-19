import Foundation
import TouchCodeCore

final class FakeHierarchyRuntime: HierarchyRuntime {
  struct SurfaceCall: Equatable {
    let panelID: PanelID
    let worktreeID: WorktreeID
  }

  private(set) var ensureSurfaceCalls: [SurfaceCall] = []
  private(set) var closeSurfaceCalls: [PanelID] = []

  func ensureSurface(for panel: Panel, in worktree: Worktree) throws {
    ensureSurfaceCalls.append(SurfaceCall(panelID: panel.id, worktreeID: worktree.id))
  }

  func closeSurface(for panelID: PanelID) {
    closeSurfaceCalls.append(panelID)
  }

  func reset() {
    ensureSurfaceCalls.removeAll()
    closeSurfaceCalls.removeAll()
  }
}
