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
  /// Makes the panel's surface NSView the window's first responder.
  /// Distinct from `focusPanel`/`settingZoomed` (catalog zoom flag) —
  /// this only flips AppKit responder-chain focus so keyboard input
  /// reaches the right surface. No-op if the surface or its window is
  /// not available.
  func focusSurfaceView(for panelID: PanelID)
}

extension HierarchyRuntime {
  func hasSurface(for panelID: PanelID) -> Bool { false }
  func focusSurfaceView(for panelID: PanelID) {}
}
