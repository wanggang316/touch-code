import Foundation
import TouchCodeCore

final class FakeHierarchyRuntime: HierarchyRuntime {
  struct SurfaceCall: Equatable {
    let paneID: PaneID
    let worktreeID: WorktreeID
  }

  private(set) var ensureSurfaceCalls: [SurfaceCall] = []
  private(set) var closeSurfaceCalls: [PaneID] = []
  /// Test-controlled liveness set. Tests assign `livePaneIDs` before
  /// calling the System Under Test; `hasSurface(for:)` returns `true`
  /// iff the pane is present.
  var livePaneIDs: Set<PaneID> = []

  func ensureSurface(for pane: Pane, in worktree: Worktree) throws {
    ensureSurfaceCalls.append(SurfaceCall(paneID: pane.id, worktreeID: worktree.id))
    livePaneIDs.insert(pane.id)
  }

  func closeSurface(for paneID: PaneID) {
    closeSurfaceCalls.append(paneID)
    livePaneIDs.remove(paneID)
  }

  func hasSurface(for paneID: PaneID) -> Bool {
    livePaneIDs.contains(paneID)
  }

  func reset() {
    ensureSurfaceCalls.removeAll()
    closeSurfaceCalls.removeAll()
    livePaneIDs.removeAll()
  }
}
