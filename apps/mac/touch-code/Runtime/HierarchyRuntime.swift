import Foundation
import TouchCodeCore

protocol HierarchyRuntime: AnyObject {
  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) throws
  func closeSurface(for paneID: PaneID)
  /// Reports whether a live terminal surface is currently registered for
  /// the given pane. Used by force-remove to size the
  /// "terminate N running processes" confirmation (spec W-Q3).
  /// Default `false` keeps legacy consumers working without changes.
  func hasSurface(for paneID: PaneID) -> Bool
  /// Makes the pane's surface NSView the window's first responder.
  /// Distinct from `focusPane`/`settingZoomed` (catalog zoom flag) —
  /// this only flips AppKit responder-chain focus so keyboard input
  /// reaches the right surface. No-op if the surface or its window is
  /// not available.
  func focusSurfaceView(for paneID: PaneID)
}

extension HierarchyRuntime {
  func hasSurface(for paneID: PaneID) -> Bool { false }
  func focusSurfaceView(for paneID: PaneID) {}
}
