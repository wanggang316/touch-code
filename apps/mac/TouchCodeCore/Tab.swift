import Foundation

public nonisolated struct Tab: Equatable, Codable, Sendable, Identifiable {
  public var id: TabID
  public var name: String?
  public var splitTree: SplitTree<PanelID>
  public var panels: [Panel]

  public init(
    id: TabID = TabID(),
    name: String? = nil,
    splitTree: SplitTree<PanelID> = SplitTree(),
    panels: [Panel] = []
  ) {
    self.id = id
    self.name = name
    self.splitTree = splitTree
    self.panels = panels
  }

  /// The set of PanelIDs that appear as leaves in the split tree.
  public var splitTreeLeafIDs: Set<PanelID> { Set(splitTree.leaves()) }

  /// The set of PanelIDs stored in the flat panels array.
  public var flatPanelIDs: Set<PanelID> { Set(panels.map(\.id)) }

  /// Invariant: leaves of `splitTree` equal IDs of `panels`. Debug-only callers.
  public enum InvariantError: Error, Equatable {
    case leavesDoNotMatchPanels(leaves: Set<PanelID>, panels: Set<PanelID>)
    case duplicatePanelIDs
  }

  public func validateInvariants() throws {
    guard flatPanelIDs.count == panels.count else { throw InvariantError.duplicatePanelIDs }
    let leaves = splitTreeLeafIDs
    let flat = flatPanelIDs
    if leaves != flat { throw InvariantError.leavesDoNotMatchPanels(leaves: leaves, panels: flat) }
  }
}
