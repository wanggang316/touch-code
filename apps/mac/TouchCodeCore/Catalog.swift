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
