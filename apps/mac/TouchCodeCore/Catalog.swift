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
  public static let currentVersion = 2

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
    // Accepts v1 (legacy — carries per-Project defaultEditor / worktreesDirectory that
    // moved to settings.json v3) and v2 (current — those fields omitted). The Project
    // decoder reads the v1 fields via `decodeIfPresent` so in-memory state carries them
    // until HierarchyManager.drainLegacyOverrides() transfers them to SettingsStore.
    guard version == 1 || version == Catalog.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    // Normalise version in-memory to currentVersion; the next save writes v2.
    self.version = Catalog.currentVersion
    self.windows = try container.decodeIfPresent([CatalogWindow].self, forKey: .windows) ?? []
    self.spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
    self.selectedSpaceID = try container.decodeIfPresent(SpaceID.self, forKey: .selectedSpaceID)
  }
}

extension Catalog {
  /// Resolve a `PaneID` to the Worktree that currently hosts it, if any.
  /// Walks `spaces → projects → worktrees → tabs → panes` and returns the
  /// first match. Linear in the total pane count. Returns `nil` if the
  /// pane has been closed or never belonged to this catalog.
  public func worktreeID(forPane paneID: PaneID) -> WorktreeID? {
    for space in spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
            return worktree.id
          }
        }
      }
    }
    return nil
  }

  /// All `PaneID`s currently living under the given Worktree, flat across
  /// every tab. Returns an empty set if the Worktree is not in the catalog.
  public func paneIDs(inWorktree worktreeID: WorktreeID) -> Set<PaneID> {
    for space in spaces {
      for project in space.projects {
        guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { continue }
        var ids: Set<PaneID> = []
        for tab in worktree.tabs {
          for pane in tab.panes { ids.insert(pane.id) }
        }
        return ids
      }
    }
    return []
  }
}
