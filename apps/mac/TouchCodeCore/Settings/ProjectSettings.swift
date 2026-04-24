import Foundation

/// `projects[<ProjectID>]` value in `settings.json` (v3). Replaces the v2
/// `RepositorySettings`. Universal top-level fields apply to both `git_repo`
/// and `plain_dir` Projects; the `git: GitProjectSettings?` nested subtree
/// carries git-kind-only overrides and is left `nil` for `plain_dir`
/// Projects or when the user has no Git / GitHub overrides set.
///
/// Every Optional field means "inherit the global default" when `nil`. The
/// garbage collector before save drops empty `ProjectSettings{}` entries
/// from the outer `Settings.projects` dict and collapses
/// `git: GitProjectSettings()` to `nil` so `settings.json` never
/// accumulates useless `{}` objects.
public nonisolated struct ProjectSettings: Equatable, Codable, Sendable {
  /// Per-Project override of the global default editor. `nil` = inherit
  /// `GeneralSettings.defaultEditorID`. Moved off `Project` in catalog.json
  /// during the v2 → v3 settings migration.
  public var defaultEditor: EditorID?

  /// Per-Project override of the global default worktree base directory.
  /// `nil` = inherit. No-op on `plain_dir` Projects (kept for data-model
  /// uniformity; a future `git init` upgrade would pick it up for free).
  public var worktreesDirectory: String?

  /// Per-Project default shell override. Reserved slot — the real picker
  /// lands in the General sub-pane follow-up wave. Always omitted from
  /// disk today because no writer sets it.
  public var defaultShell: String?

  /// Environment variables injected into new panes opened under this
  /// Project. Empty by default. Reserved slot — the Environment sub-pane
  /// fills in the editing UI in a follow-up wave.
  public var envVars: [String: String]

  /// User-defined scripts surfaced in the Scripts sub-pane and command
  /// palette. Empty by default. Reserved slot — `ScriptDefinition` is a
  /// placeholder pending the Scripts sub-pane follow-up wave.
  public var scripts: [ScriptDefinition]

  /// Git-kind-only subtree. `nil` on `plain_dir` Projects or whenever
  /// every git-subtree field is at its default. Collapsed to `nil` by
  /// `isEffectivelyEmpty`-checking garbage collection before save.
  public var git: GitProjectSettings?

  public init(
    defaultEditor: EditorID? = nil,
    worktreesDirectory: String? = nil,
    defaultShell: String? = nil,
    envVars: [String: String] = [:],
    scripts: [ScriptDefinition] = [],
    git: GitProjectSettings? = nil
  ) {
    self.defaultEditor = defaultEditor
    self.worktreesDirectory = worktreesDirectory
    self.defaultShell = defaultShell
    self.envVars = envVars
    self.scripts = scripts
    self.git = git
  }

  /// True when every field is at its default AND `git` is either nil or
  /// itself effectively empty. The outer `Settings.garbageCollect()`
  /// drops `projects[pid]` entries whose value answers `true` here.
  public var isEffectivelyEmpty: Bool {
    defaultEditor == nil
      && worktreesDirectory == nil
      && defaultShell == nil
      && envVars.isEmpty
      && scripts.isEmpty
      && (git?.isEffectivelyEmpty ?? true)
  }

  /// Mutating helper for garbage collection: collapse `git` to `nil`
  /// when the nested subtree is effectively empty. Called by
  /// `Settings.garbageCollect()` per entry before save so empty git
  /// subtrees do not persist as `"git": {}` on disk.
  public mutating func collapseEmptyGit() {
    if let git, git.isEffectivelyEmpty {
      self.git = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case defaultEditor
    case worktreesDirectory
    case defaultShell
    case envVars
    case scripts
    case git
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.defaultEditor = try c.decodeIfPresent(EditorID.self, forKey: .defaultEditor)
    self.worktreesDirectory = try c.decodeIfPresent(String.self, forKey: .worktreesDirectory)
    self.defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell)
    self.envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
    self.scripts = try c.decodeIfPresent([ScriptDefinition].self, forKey: .scripts) ?? []
    self.git = try c.decodeIfPresent(GitProjectSettings.self, forKey: .git)
  }

  /// Omit-when-default encoding. Empty collections / nil Optionals / an
  /// effectively-empty `git` do not appear in the JSON object.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(defaultEditor, forKey: .defaultEditor)
    try c.encodeIfPresent(worktreesDirectory, forKey: .worktreesDirectory)
    try c.encodeIfPresent(defaultShell, forKey: .defaultShell)
    if !envVars.isEmpty {
      try c.encode(envVars, forKey: .envVars)
    }
    if !scripts.isEmpty {
      try c.encode(scripts, forKey: .scripts)
    }
    if let git, !git.isEffectivelyEmpty {
      try c.encode(git, forKey: .git)
    }
  }
}
