import Foundation

/// `general` sub-tree of `settings.json` (v2). Carries the appearance placeholder plus the
/// global default `EditorID` used when no per-Project override is set. C8a retired the
/// `customEditors` array that C8 shipped; legacy files that still carry it decode cleanly
/// (the field is simply ignored) and are re-serialised without it on the next save.
public nonisolated struct GeneralSettings: Equatable, Codable, Sendable {
  public var appearance: AppearancePreference
  /// Global default editor. `nil` means "no global default set" — resolution falls back to
  /// the `EditorRegistry.defaultPriority` walk (which always terminates at Finder).
  public var defaultEditorID: EditorID?

  public init(
    appearance: AppearancePreference = .system,
    defaultEditorID: EditorID? = nil
  ) {
    self.appearance = appearance
    self.defaultEditorID = defaultEditorID
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey { case appearance, defaultEditorID }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
  }
}
