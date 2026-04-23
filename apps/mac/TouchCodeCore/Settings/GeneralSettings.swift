import Foundation

/// `general` sub-tree of `settings.json` (v2). Carries the appearance placeholder, the
/// global default `EditorID`, and global defaults for the GitHub integration. C8a retired
/// the `customEditors` array that C8 shipped; legacy files that still carry it decode
/// cleanly (the field is simply ignored) and are re-serialised without it on the next save.
public nonisolated struct GeneralSettings: Equatable, Codable, Sendable {
  public var appearance: AppearancePreference
  /// Global default editor. `nil` means "no global default set" — resolution falls back to
  /// the `EditorRegistry.defaultPriority` walk (which always terminates at Finder).
  public var defaultEditorID: EditorID?
  /// Global default merge strategy used by the GitHub popover's Merge split-button when no
  /// per-Project `RepositorySettings.defaultMergeStrategy` is set. `nil` means "no global
  /// default" — the picker falls back to `.squash` for its initial value.
  public var defaultMergeStrategy: MergeStrategy?
  /// Global default post-merge Worktree action used by the GitHub integration when no
  /// per-Project override is set. `nil` means "no global default" — merging a PR presents
  /// the ask-each-time sheet.
  public var postMergeAction: MergedWorktreeAction?

  public init(
    appearance: AppearancePreference = .system,
    defaultEditorID: EditorID? = nil,
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil
  ) {
    self.appearance = appearance
    self.defaultEditorID = defaultEditorID
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey {
    case appearance, defaultEditorID, defaultMergeStrategy, postMergeAction
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
    self.defaultMergeStrategy = try container.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try container.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
  }
}
