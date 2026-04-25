import Foundation

/// Git-kind-only per-Project preferences nested under
/// `ProjectSettings.git`. Present when the user has at least one Git /
/// GitHub override set on a `git_repo` Project; cleared to `nil` by the
/// garbage collector before save whenever every field is at its default.
///
/// Most fields are `Optional<T>`: `nil` means "inherit the global default"
/// (from `GeneralSettings`). `githubDisabled` is a plain `Bool` defaulting
/// to `false` — the common case is "GitHub integration on" and the
/// omit-when-default encoder leaves it off disk unless the user flipped it.
public nonisolated struct GitProjectSettings: Equatable, Codable, Sendable {
  public var worktreeBaseRef: String?
  public var copyIgnoredOnWorktreeCreate: Bool?
  public var copyUntrackedOnWorktreeCreate: Bool?
  public var defaultMergeStrategy: MergeStrategy?
  public var postMergeAction: MergedWorktreeAction?
  public var githubDisabled: Bool

  public init(
    worktreeBaseRef: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    githubDisabled: Bool = false
  ) {
    self.worktreeBaseRef = worktreeBaseRef
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
    self.githubDisabled = githubDisabled
  }

  /// True when every field is at its default. `ProjectSettings` clears
  /// its `git` child to `nil` when this is true before save, so
  /// `settings.json` does not accumulate useless `"git": {}` objects.
  public var isEffectivelyEmpty: Bool {
    worktreeBaseRef == nil
      && copyIgnoredOnWorktreeCreate == nil
      && copyUntrackedOnWorktreeCreate == nil
      && defaultMergeStrategy == nil
      && postMergeAction == nil
      && githubDisabled == false
  }

  private enum CodingKeys: String, CodingKey {
    case worktreeBaseRef
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case defaultMergeStrategy
    case postMergeAction
    case githubDisabled
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.worktreeBaseRef = try c.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    self.copyIgnoredOnWorktreeCreate = try c.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
    self.copyUntrackedOnWorktreeCreate = try c.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
    self.defaultMergeStrategy = try c.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try c.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
    self.githubDisabled = try c.decodeIfPresent(Bool.self, forKey: .githubDisabled) ?? false
  }

  /// Omit-when-default encoding — matches `RepositorySettings`' existing
  /// shape so the migrated-from-v2 `git` subtree in `settings.json` stays
  /// byte-stable over round-trips.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(worktreeBaseRef, forKey: .worktreeBaseRef)
    try c.encodeIfPresent(copyIgnoredOnWorktreeCreate, forKey: .copyIgnoredOnWorktreeCreate)
    try c.encodeIfPresent(copyUntrackedOnWorktreeCreate, forKey: .copyUntrackedOnWorktreeCreate)
    try c.encodeIfPresent(defaultMergeStrategy, forKey: .defaultMergeStrategy)
    try c.encodeIfPresent(postMergeAction, forKey: .postMergeAction)
    if githubDisabled {
      try c.encode(true, forKey: .githubDisabled)
    }
  }
}
