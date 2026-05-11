import Foundation

public nonisolated struct Tab: Equatable, Codable, Sendable, Identifiable {
  public var id: TabID
  public var name: String?
  /// Snapshot of the most recently resolved live title (OSC tabTitle /
  /// title / pwd basename). Persisted to the catalog so a tab whose
  /// surface has not yet been re-spawned after app launch still shows
  /// the previous session's title instead of falling back to "Tab N".
  /// Cleared / overwritten as soon as a live title is observed again.
  public var cachedDisplayTitle: String?
  /// Per-tab accent color for the active underline stripe. `nil` = system accent.
  public var color: TabColor?
  public var splitTree: SplitTree<PaneID>
  public var panes: [Pane]

  public init(
    id: TabID = TabID(),
    name: String? = nil,
    cachedDisplayTitle: String? = nil,
    color: TabColor? = nil,
    splitTree: SplitTree<PaneID> = SplitTree(),
    panes: [Pane] = []
  ) {
    self.id = id
    self.name = name
    self.cachedDisplayTitle = cachedDisplayTitle
    self.color = color
    self.splitTree = splitTree
    self.panes = panes
  }

  /// The set of PaneIDs that appear as leaves in the split tree.
  public var splitTreeLeafIDs: Set<PaneID> { Set(splitTree.leaves()) }

  /// The set of PaneIDs stored in the flat panes array.
  public var flatPaneIDs: Set<PaneID> { Set(panes.map(\.id)) }

  /// Invariant: leaves of `splitTree` equal IDs of `panes`. Debug-only callers.
  public enum InvariantError: Error, Equatable {
    case leavesDoNotMatchPanes(leaves: Set<PaneID>, panes: Set<PaneID>)
    case duplicatePaneIDs
  }

  public func validateInvariants() throws {
    guard flatPaneIDs.count == panes.count else { throw InvariantError.duplicatePaneIDs }
    let leaves = splitTreeLeafIDs
    let flat = flatPaneIDs
    if leaves != flat { throw InvariantError.leavesDoNotMatchPanes(leaves: leaves, panes: flat) }
  }
}
