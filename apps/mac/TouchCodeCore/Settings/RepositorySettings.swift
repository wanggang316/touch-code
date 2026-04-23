import Foundation

/// `repositories[<ProjectID>]` value in `settings.json` (v2). **Reserved-empty in T1** —
/// exec-plan 0012 M1 adds the first per-Project preferences: GitHub integration overrides.
/// Fields added additively (Codable `decodeIfPresent` + omit-when-default encode) so
/// pre-integration `settings.json` files round-trip identically and no schema version bump
/// is needed.
public nonisolated struct RepositorySettings: Equatable, Codable, Sendable {
  /// Per-Project override of the global default merge strategy. When non-nil, the merge
  /// split-button's primary face uses this. When nil, the button falls back to
  /// `GeneralSettings.defaultMergeStrategy`, then to `.squash` as the picker's initial value.
  public var defaultMergeStrategy: MergeStrategy?

  /// Per-Project override of the global post-merge Worktree action. When non-nil, merging
  /// a PR from this Project's Worktrees triggers this action without a sheet. When nil,
  /// the resolver falls through to `GeneralSettings.postMergeAction`, then to `.ask`.
  public var postMergeAction: MergedWorktreeAction?

  /// Per-Project toggle that suppresses every visible surface of the GitHub integration
  /// (badges, popover, palette entries) for this Project. Defaults to `false` — the
  /// feature is on by default per exec-plan 0012 DEC-1.
  public var githubDisabled: Bool

  public init(
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    githubDisabled: Bool = false
  ) {
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
    self.githubDisabled = githubDisabled
  }

  /// True when this entry carries no per-Repo preferences. `SettingsStore` GCs such
  /// entries before each save so `settings.json` does not accumulate useless `{}` objects.
  public var isEffectivelyEmpty: Bool {
    defaultMergeStrategy == nil && postMergeAction == nil && githubDisabled == false
  }

  private enum CodingKeys: String, CodingKey {
    case defaultMergeStrategy, postMergeAction, githubDisabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.defaultMergeStrategy = try container.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try container.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
    self.githubDisabled = try container.decodeIfPresent(Bool.self, forKey: .githubDisabled) ?? false
  }

  /// Encode with omit-when-default semantics so an empty `RepositorySettings{}` round-trips
  /// as `{}`, matching the pre-integration on-disk shape. `garbageCollect()` on `Settings`
  /// strips empty entries entirely before save.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(defaultMergeStrategy, forKey: .defaultMergeStrategy)
    try container.encodeIfPresent(postMergeAction, forKey: .postMergeAction)
    if githubDisabled {
      try container.encode(true, forKey: .githubDisabled)
    }
  }
}
