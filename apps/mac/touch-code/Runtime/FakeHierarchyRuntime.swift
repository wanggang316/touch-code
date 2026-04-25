import Foundation
import TouchCodeCore

final class FakeHierarchyRuntime: HierarchyRuntime {
  struct SurfaceCall: Equatable {
    let paneID: PaneID
    let worktreeID: WorktreeID
    let env: [String: String]
  }

  private(set) var ensureSurfaceCalls: [SurfaceCall] = []
  private(set) var closeSurfaceCalls: [PaneID] = []
  /// Recorded `focusSurfaceView` calls. The manager's tab-switch path
  /// invokes this on the restored last-focused (or leftmost-leaf) pane
  /// id; tests assert the right pane was requested.
  private(set) var focusSurfaceViewCalls: [PaneID] = []
  /// Test-controlled liveness set. Tests assign `livePaneIDs` before
  /// calling the System Under Test; `hasSurface(for:)` returns `true`
  /// iff the pane is present.
  var livePaneIDs: Set<PaneID> = []

  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) throws {
    ensureSurfaceCalls.append(
      SurfaceCall(paneID: pane.id, worktreeID: worktree.id, env: env)
    )
    livePaneIDs.insert(pane.id)
  }

  func closeSurface(for paneID: PaneID) {
    closeSurfaceCalls.append(paneID)
    livePaneIDs.remove(paneID)
  }

  func hasSurface(for paneID: PaneID) -> Bool {
    livePaneIDs.contains(paneID)
  }

  func focusSurfaceView(for paneID: PaneID) {
    focusSurfaceViewCalls.append(paneID)
  }

  func reset() {
    ensureSurfaceCalls.removeAll()
    closeSurfaceCalls.removeAll()
    focusSurfaceViewCalls.removeAll()
    livePaneIDs.removeAll()
  }
}
