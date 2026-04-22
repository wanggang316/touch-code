import Foundation

/// Tab / split intent decoded from a libghostty surface-scoped action.
/// The Runtime emits `TerminalEvent.panelActionRequested(panelID, request)`;
/// `PanelActionRouterFeature` resolves the request against `HierarchyClient`.
///
/// Intents are policy-free: the reducer decides whether a close is allowed,
/// how to handle a running process, etc. Runtime stays TCA-free by only
/// lifting the typed intent onto the event stream.
public nonisolated enum PanelActionRequest: Sendable, Equatable {
  case newTab
  case closeTab(mode: CloseTabMode)
  case moveTab(offset: Int)
  case gotoTab(target: GotoTabTarget)
  case newSplit(direction: NewSplitDirection)
  case gotoSplit(direction: FocusDirection)
  case resizeSplit(direction: ResizeDirection, amount: Double)
  case equalizeSplits
  case toggleSplitZoom
  case presentTerminal
  case toggleCommandPalette
}

public nonisolated enum CloseTabMode: Sendable, Equatable {
  case this
  case other
  case right
}

public nonisolated enum GotoTabTarget: Sendable, Equatable {
  case previous
  case next
  case last
  case index(Int)
}

public nonisolated enum NewSplitDirection: Sendable, Equatable {
  case horizontal
  case vertical
}

public nonisolated enum FocusDirection: Sendable, Equatable {
  case up
  case down
  case left
  case right
  case previous
  case next
}

public nonisolated enum ResizeDirection: Sendable, Equatable {
  case up
  case down
  case left
  case right
}
