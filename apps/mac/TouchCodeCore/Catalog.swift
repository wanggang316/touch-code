import Foundation

public nonisolated struct CatalogWindow: Equatable, Codable, Sendable, Identifiable {
  public var id: UUID
  public var selectedSpaceID: SpaceID?

  public init(id: UUID = UUID(), selectedSpaceID: SpaceID? = nil) {
    self.id = id
    self.selectedSpaceID = selectedSpaceID
  }
}

public nonisolated struct Catalog: Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var windows: [CatalogWindow]
  public var spaces: [Space]
  public var selectedSpaceID: SpaceID?

  public init(
    version: Int = Catalog.currentVersion,
    windows: [CatalogWindow] = [],
    spaces: [Space] = [],
    selectedSpaceID: SpaceID? = nil
  ) {
    self.version = version
    self.windows = windows
    self.spaces = spaces
    self.selectedSpaceID = selectedSpaceID
  }

  public static let empty = Catalog()

  /// The canonical on-disk location: `~/.config/touch-code/catalog.json`.
  public static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("catalog.json", isDirectory: false)
  }
}

extension Catalog: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey { case version, windows, spaces, selectedSpaceID }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Catalog.currentVersion else { throw DecodingIssue.unsupportedVersion(version) }
    self.version = version
    self.windows = try container.decodeIfPresent([CatalogWindow].self, forKey: .windows) ?? []
    self.spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
    self.selectedSpaceID = try container.decodeIfPresent(SpaceID.self, forKey: .selectedSpaceID)
  }
}

extension Catalog {
  /// Resets any `Project.defaultEditor` that is not in the caller-provided built-in
  /// registry to `nil`. Counterpart to `Settings.garbageCollectEditors` — run once at
  /// catalog load so per-project overrides left over from the retired C8 `customEditors`
  /// feature don't persist forever. `knownIDs` is a parameter so this helper stays in
  /// `TouchCodeCore` without pulling in the app-tier `EditorRegistry`.
  ///
  /// Idempotent: a second call on an already-cleaned `Catalog` is a no-op and returns
  /// `false`. Returns `true` if any Project was mutated so the caller can decide whether
  /// to persist — avoids a spurious catalog write when nothing actually changed.
  @discardableResult
  public mutating func garbageCollectEditors(knownIDs: Set<EditorID>) -> Bool {
    var mutated = false
    for spaceIndex in spaces.indices {
      for projectIndex in spaces[spaceIndex].projects.indices {
        if let id = spaces[spaceIndex].projects[projectIndex].defaultEditor,
          !knownIDs.contains(id)
        {
          spaces[spaceIndex].projects[projectIndex].defaultEditor = nil
          mutated = true
        }
      }
    }
    return mutated
  }

  /// Resolve a `PanelID` to the Worktree that currently hosts it, if any.
  /// Walks `spaces → projects → worktrees → tabs → panels` and returns the
  /// first match. Linear in the total panel count. Returns `nil` if the
  /// panel has been closed or never belonged to this catalog.
  public func worktreeID(forPanel panelID: PanelID) -> WorktreeID? {
    for space in spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs where tab.panels.contains(where: { $0.id == panelID }) {
            return worktree.id
          }
        }
      }
    }
    return nil
  }

  /// All `PanelID`s currently living under the given Worktree, flat across
  /// every tab. Returns an empty set if the Worktree is not in the catalog.
  public func panelIDs(inWorktree worktreeID: WorktreeID) -> Set<PanelID> {
    for space in spaces {
      for project in space.projects {
        guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { continue }
        var ids: Set<PanelID> = []
        for tab in worktree.tabs {
          for panel in tab.panels { ids.insert(panel.id) }
        }
        return ids
      }
    }
    return []
  }
}
