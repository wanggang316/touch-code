import Foundation

public nonisolated struct Tab: Equatable, Codable, Sendable, Identifiable {
  public var id: TabID
  public var name: String?
  public var splitTree: SplitTree<PaneID>
  public var panes: [Pane]

  public init(
    id: TabID = TabID(),
    name: String? = nil,
    splitTree: SplitTree<PaneID> = SplitTree(),
    panes: [Pane] = []
  ) {
    self.id = id
    self.name = name
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
