import Foundation

/// `general` sub-tree of `settings.json` (v2). Owns the appearance placeholder plus every
/// editor-related global: the default `EditorID` used when no per-Project override is set
/// and the user-authored custom templates. Fields migrate 1:1 from v1 `Settings.defaultEditorID`
/// + `Settings.customEditors`.
public nonisolated struct GeneralSettings: Equatable, Codable, Sendable {
  public var appearance: AppearancePreference
  /// Global default editor. `nil` means "no global default set" — resolution falls back to Finder.
  public var defaultEditorID: EditorID?
  /// User-defined editor templates. IDs must not collide with any built-in editor.
  public var customEditors: [CustomEditor]

  public init(
    appearance: AppearancePreference = .system,
    defaultEditorID: EditorID? = nil,
    customEditors: [CustomEditor] = []
  ) {
    self.appearance = appearance
    self.defaultEditorID = defaultEditorID
    self.customEditors = customEditors
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey { case appearance, defaultEditorID, customEditors }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
    self.customEditors = try container.decodeIfPresent([CustomEditor].self, forKey: .customEditors) ?? []
  }
}
