import Foundation
import os.log

public nonisolated struct Catalog: Equatable, Sendable {
  public static let currentVersion = 3

  public var version: Int
  public var projects: [Project]
  public var tags: [Tag]
  public var activeTagFilter: TagFilter
  /// Authoritative top-level "the user's current Project". Promoted in v3
  /// from `Space.selectedProjectID` (which itself was demoted from
  /// `Catalog.selectedSpaceID` in v2). Single-window simplification means
  /// there is exactly one such selection per app — no per-Window or
  /// per-Space ambiguity. The selection-stream resolver in
  /// `HierarchyClient` reads this first; it falls back to the first
  /// Project carrying a non-nil `selectedWorktreeID` only when this
  /// field is nil (initial-load path).
  public var selectedProjectID: ProjectID?

  public init(
    version: Int = Catalog.currentVersion,
    projects: [Project] = [],
    tags: [Tag] = [],
    activeTagFilter: TagFilter = .all,
    selectedProjectID: ProjectID? = nil
  ) {
    self.version = version
    self.projects = projects
    self.tags = tags
    self.activeTagFilter = activeTagFilter
    self.selectedProjectID = selectedProjectID
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

  private enum CodingKeys: String, CodingKey {
    case version, projects, tags, activeTagFilter, selectedProjectID
    // v1/v2-only (decoded for migration, never encoded): spaces, windows, selectedSpaceID
    case spaces, windows, selectedSpaceID
  }

  /// Fixed Finder-style palette assigned in order to migrated Spaces. Cycles
  /// after seven Spaces — extremely uncommon to have more.
  fileprivate static let migrationPalette: [TagColor] = [
    .blue, .orange, .green, .purple, .red, .yellow, .grey,
  ]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version >= 1, version <= Catalog.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }

    if version == Catalog.currentVersion {
      // Native v3 read path.
      self.version = Catalog.currentVersion
      self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
      self.tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
      self.activeTagFilter =
        try container.decodeIfPresent(TagFilter.self, forKey: .activeTagFilter) ?? .all
      self.selectedProjectID =
        try container.decodeIfPresent(ProjectID.self, forKey: .selectedProjectID)
      return
    }

    // v1/v2 → v3 migration. v1 carries per-Project legacy fields
    // (`defaultEditor`, `worktreesDirectory`) which the Project decoder
    // already drains via `LegacyV1CodingKeys`; we don't need to handle that
    // here. The Space layer goes away entirely — each Space becomes a Tag,
    // and every Project under it inherits that Tag.
    let legacySpaces = try container.decodeIfPresent([LegacySpaceV2].self, forKey: .spaces) ?? []
    let legacyWindows =
      try container.decodeIfPresent([LegacyCatalogWindowV2].self, forKey: .windows) ?? []
    let selectedSpaceID =
      try container.decodeIfPresent(LegacySpaceIDV2.self, forKey: .selectedSpaceID)

    var spaceIDToTagID: [LegacySpaceIDV2: TagID] = [:]
    var migratedTags: [Tag] = []
    var migratedProjects: [Project] = []
    let palette = Catalog.migrationPalette
    for (idx, space) in legacySpaces.enumerated() {
      let tag = Tag(name: space.name, color: palette[idx % palette.count])
      spaceIDToTagID[space.id] = tag.id
      migratedTags.append(tag)
      for var project in space.projects {
        project.tagIDs.insert(tag.id)
        migratedProjects.append(project)
      }
    }

    // Pick the seed filter: the catalog's selected space wins; otherwise the
    // first window with a non-nil selection; otherwise no filter. Multi-window
    // catalogs collapse — only one filter survives.
    let seedSpaceID =
      selectedSpaceID ?? legacyWindows.compactMap { $0.selectedSpaceID }.first
    let migratedFilter: TagFilter =
      seedSpaceID.flatMap { spaceIDToTagID[$0] }.map { .tags([$0]) } ?? .all

    let log = OSLog(subsystem: "com.touch-code", category: "catalog")
    os_log(
      .info,
      log: log,
      "migrated catalog v%d → v3 (%d spaces → %d tags, %d projects)",
      version, legacySpaces.count, migratedTags.count, migratedProjects.count
    )

    self.version = Catalog.currentVersion
    self.projects = migratedProjects
    self.tags = migratedTags
    self.activeTagFilter = migratedFilter
    // v2 had `Space.selectedProjectID` but it lived per-space; promoting
    // it to the top-level v3 field would require knowing which Space's
    // selection wins. We drop it on migration — the user's first
    // sidebar interaction in the new build sets the v3 field cleanly.
    self.selectedProjectID = nil
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(projects, forKey: .projects)
    try container.encode(tags, forKey: .tags)
    // Encode `activeTagFilter` only when it diverges from the default `.all`.
    // Pre-tag catalogs without the key decode to `.all`, so writes stay
    // byte-identical when the filter is unset.
    if activeTagFilter != .all {
      try container.encode(activeTagFilter, forKey: .activeTagFilter)
    }
    try container.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
  }
}

// MARK: - Legacy v1/v2 decoder shapes

/// Migration-only mirrors of the v1/v2 Space, CatalogWindow, and SpaceID
/// types. Lives private to the catalog so the rest of the codebase has no
/// compile-time knowledge of the dropped concepts. These structs decode the
/// legacy shape; the migration code in `Catalog.init(from:)` walks them and
/// produces v3 Tags + flat Projects.
private struct LegacySpaceIDV2: Codable, Hashable {
  let raw: UUID
}

private struct LegacySpaceV2: Codable {
  let id: LegacySpaceIDV2
  let name: String
  let projects: [Project]

  private enum CodingKeys: String, CodingKey {
    case id, name, projects
    // Decoded but unused (already-deprecated v2 fields):
    // selectedProjectID, lastActiveWorktreeID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(LegacySpaceIDV2.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
  }

  func encode(to encoder: Encoder) throws {
    fatalError("LegacySpaceV2 is decode-only")
  }
}

private struct LegacyCatalogWindowV2: Codable {
  let selectedSpaceID: LegacySpaceIDV2?

  private enum CodingKeys: String, CodingKey {
    case selectedSpaceID
  }
}

extension Catalog {
  /// Resolve a `PaneID` to the Worktree that currently hosts it, if any.
  /// Walks `projects → worktrees → tabs → panes` and returns the first
  /// match. Linear in the total pane count.
  public func worktreeID(forPane paneID: PaneID) -> WorktreeID? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return worktree.id
        }
      }
    }
    return nil
  }

  /// All `PaneID`s currently living under the given Worktree, flat across
  /// every tab. Returns an empty set if the Worktree is not in the catalog.
  public func paneIDs(inWorktree worktreeID: WorktreeID) -> Set<PaneID> {
    for project in projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else {
        continue
      }
      var ids: Set<PaneID> = []
      for tab in worktree.tabs {
        for pane in tab.panes { ids.insert(pane.id) }
      }
      return ids
    }
    return []
  }
}
