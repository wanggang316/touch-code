import Foundation
import TouchCodeCore

final class FakeHierarchyRuntime: HierarchyRuntime {
  struct SurfaceCall: Equatable {
    let panelID: PanelID
    let worktreeID: WorktreeID
  }

  private(set) var ensureSurfaceCalls: [SurfaceCall] = []
  private(set) var closeSurfaceCalls: [PanelID] = []
  /// Test-controlled liveness set. Tests assign `livePanelIDs` before
  /// calling the System Under Test; `hasSurface(for:)` returns `true`
  /// iff the panel is present.
  var livePanelIDs: Set<PanelID> = []

  func ensureSurface(for panel: Panel, in worktree: Worktree) throws {
    ensureSurfaceCalls.append(SurfaceCall(panelID: panel.id, worktreeID: worktree.id))
    livePanelIDs.insert(panel.id)
  }

  func closeSurface(for panelID: PanelID) {
    closeSurfaceCalls.append(panelID)
    livePanelIDs.remove(panelID)
  }

  func hasSurface(for panelID: PanelID) -> Bool {
    livePanelIDs.contains(panelID)
  }

  func reset() {
    ensureSurfaceCalls.removeAll()
    closeSurfaceCalls.removeAll()
    livePanelIDs.removeAll()
  }
}
