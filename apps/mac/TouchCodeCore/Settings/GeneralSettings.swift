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
  /// Global default Git viewer. `nil` means "use the built-in Git Viewer overlay"; any
  /// other value names an installed git client from `EditorRegistry.gitClientPriority`
  /// (GitHub Desktop, Sourcetree, …) that should open instead when the user invokes the
  /// Git Viewer chord / menu item. A stored id that is no longer installed is treated
  /// as `nil` at resolve time and cleaned up by `garbageCollectEditors`.
  public var defaultGitViewerID: EditorID?
  /// Global default merge strategy used by the GitHub popover's Merge split-button when no
  /// per-Project `RepositorySettings.defaultMergeStrategy` is set. `nil` means "no global
  /// default" — the picker falls back to `.squash` for its initial value.
  public var defaultMergeStrategy: MergeStrategy?
  /// Global default post-merge Worktree action used by the GitHub integration when no
  /// per-Project override is set. `nil` means "no global default" — merging a PR presents
  /// the ask-each-time sheet.
  public var postMergeAction: MergedWorktreeAction?

  /// Sparkle release channel. Default `stable`. Drives both
  /// `SPUUpdaterDelegate.allowedChannels(for:)` and the background-check interval — the
  /// app pushes this to `SPUUpdater` on launch and on every change.
  public var updateChannel: UpdateChannel
  /// Whether Sparkle should poll for updates in the background. Default `true`.
  public var updatesAutomaticallyCheckForUpdates: Bool
  /// Whether Sparkle should download + install updates without prompting. Default `false`
  /// because automatic install requires the app to relaunch and the user might be in the
  /// middle of a long-running terminal task. Only takes effect when
  /// `updatesAutomaticallyCheckForUpdates` is also true.
  public var updatesAutomaticallyDownloadUpdates: Bool

  public init(
    appearance: AppearancePreference = .system,
    defaultEditorID: EditorID? = nil,
    defaultGitViewerID: EditorID? = nil,
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    updateChannel: UpdateChannel = .stable,
    updatesAutomaticallyCheckForUpdates: Bool = true,
    updatesAutomaticallyDownloadUpdates: Bool = false
  ) {
    self.appearance = appearance
    self.defaultEditorID = defaultEditorID
    self.defaultGitViewerID = defaultGitViewerID
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
    self.updateChannel = updateChannel
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey {
    case appearance, defaultEditorID, defaultGitViewerID, defaultMergeStrategy, postMergeAction
    case updateChannel, updatesAutomaticallyCheckForUpdates, updatesAutomaticallyDownloadUpdates
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
    self.defaultGitViewerID = try container.decodeIfPresent(EditorID.self, forKey: .defaultGitViewerID)
    self.defaultMergeStrategy = try container.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try container.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
    self.updateChannel =
      try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .stable
    self.updatesAutomaticallyCheckForUpdates =
      try container.decodeIfPresent(Bool.self, forKey: .updatesAutomaticallyCheckForUpdates) ?? true
    self.updatesAutomaticallyDownloadUpdates =
      try container.decodeIfPresent(Bool.self, forKey: .updatesAutomaticallyDownloadUpdates) ?? false
  }
}
