import Foundation

/// User-editable preferences persisted at `~/.config/touch-code/settings.json`.
/// Owned by the app's `SettingsStore`. The schema is versioned; readers that encounter an
/// unknown `version` throw instead of silently upgrading, matching the architecture-wide
/// persistence invariant.
public nonisolated struct Settings: Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  /// Global default editor ID. `nil` means "no global default set" — resolution falls back
  /// to Finder.
  public var defaultEditorID: EditorID?
  /// User-defined editor templates. IDs must not collide with any built-in editor
  /// (`EditorRegistry.builtins`); validation enforced at save time.
  public var customEditors: [CustomEditor]

  public init(
    version: Int = Settings.currentVersion,
    defaultEditorID: EditorID? = nil,
    customEditors: [CustomEditor] = []
  ) {
    self.version = version
    self.defaultEditorID = defaultEditorID
    self.customEditors = customEditors
  }

  public static let `default` = Settings()

  /// The canonical on-disk location: `~/.config/touch-code/settings.json`.
  public static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("settings.json", isDirectory: false)
  }
}

extension Settings: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case version, defaultEditorID, customEditors
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Settings.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = version
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
    self.customEditors = try container.decodeIfPresent([CustomEditor].self, forKey: .customEditors) ?? []
  }
}
