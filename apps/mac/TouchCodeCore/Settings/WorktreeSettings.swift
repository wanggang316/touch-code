import Foundation

/// Auto-delete period for archived worktrees. Represents the number of days after
/// which a worktree archived via `tc worktree archive` is automatically deleted.
public nonisolated enum AutoDeletePeriod: Int, Equatable, Codable, Sendable, CaseIterable {
  case oneDay = 1
  case threeDays = 3
  case sevenDays = 7
  case fourteenDays = 14
  case thirtyDays = 30

  public var label: String {
    switch self {
    case .oneDay: return "1 day"
    case .threeDays: return "3 days"
    case .sevenDays: return "7 days"
    case .fourteenDays: return "14 days"
    case .thirtyDays: return "30 days"
    }
  }
}

/// `worktree` sub-tree of `settings.json` (v3). Global defaults for worktree creation
/// and management, used across all projects unless overridden per-project.
public nonisolated struct WorktreeSettings: Equatable, Codable, Sendable {
  /// Global default directory for cloning new worktrees. When `nil`, each project uses
  /// its own default (typically `~/.touch-code/repos/<projectName>/`). Projects can
  /// override this with their own `ProjectSettings.worktreesDirectory`.
  public var defaultWorktreesDirectory: String?
  /// Whether to fetch the remote before creating a new worktree. Default `true`.
  public var fetchRemoteOnCreate: Bool
  /// Whether to copy `.gitignore`-listed files when creating a worktree. Default `false`.
  public var copyIgnoredOnCreate: Bool
  /// Whether to copy untracked files when creating a worktree. Default `false`.
  public var copyUntrackedOnCreate: Bool
  /// Whether to automatically delete archived worktrees after a period. Default `false`.
  public var autoDeleteArchived: Bool
  /// Period (in days) after which archived worktrees are auto-deleted. Ignored if
  /// `autoDeleteArchived` is false. Default `.sevenDays`.
  public var autoDeletePeriod: AutoDeletePeriod
  /// Whether to delete the remote branch when deleting a local worktree. Default `false`.
  public var deleteRemoteBranchWithWorktree: Bool

  public init(
    defaultWorktreesDirectory: String? = nil,
    fetchRemoteOnCreate: Bool = true,
    copyIgnoredOnCreate: Bool = false,
    copyUntrackedOnCreate: Bool = false,
    autoDeleteArchived: Bool = false,
    autoDeletePeriod: AutoDeletePeriod = .sevenDays,
    deleteRemoteBranchWithWorktree: Bool = false
  ) {
    self.defaultWorktreesDirectory = defaultWorktreesDirectory
    self.fetchRemoteOnCreate = fetchRemoteOnCreate
    self.copyIgnoredOnCreate = copyIgnoredOnCreate
    self.copyUntrackedOnCreate = copyUntrackedOnCreate
    self.autoDeleteArchived = autoDeleteArchived
    self.autoDeletePeriod = autoDeletePeriod
    self.deleteRemoteBranchWithWorktree = deleteRemoteBranchWithWorktree
  }

  public static let `default` = WorktreeSettings()

  private enum CodingKeys: String, CodingKey {
    case defaultWorktreesDirectory, fetchRemoteOnCreate, copyIgnoredOnCreate
    case copyUntrackedOnCreate, autoDeleteArchived, autoDeletePeriod, deleteRemoteBranchWithWorktree
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.defaultWorktreesDirectory = try container.decodeIfPresent(String.self, forKey: .defaultWorktreesDirectory)
    self.fetchRemoteOnCreate = try container.decodeIfPresent(Bool.self, forKey: .fetchRemoteOnCreate) ?? true
    self.copyIgnoredOnCreate = try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnCreate) ?? false
    self.copyUntrackedOnCreate = try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnCreate) ?? false
    self.autoDeleteArchived = try container.decodeIfPresent(Bool.self, forKey: .autoDeleteArchived) ?? false
    self.autoDeletePeriod = try container.decodeIfPresent(AutoDeletePeriod.self, forKey: .autoDeletePeriod) ?? .sevenDays
    self.deleteRemoteBranchWithWorktree = try container.decodeIfPresent(Bool.self, forKey: .deleteRemoteBranchWithWorktree) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(defaultWorktreesDirectory, forKey: .defaultWorktreesDirectory)
    if fetchRemoteOnCreate != true {
      try container.encode(fetchRemoteOnCreate, forKey: .fetchRemoteOnCreate)
    }
    if copyIgnoredOnCreate != false {
      try container.encode(copyIgnoredOnCreate, forKey: .copyIgnoredOnCreate)
    }
    if copyUntrackedOnCreate != false {
      try container.encode(copyUntrackedOnCreate, forKey: .copyUntrackedOnCreate)
    }
    if autoDeleteArchived != false {
      try container.encode(autoDeleteArchived, forKey: .autoDeleteArchived)
    }
    if autoDeletePeriod != .sevenDays {
      try container.encode(autoDeletePeriod, forKey: .autoDeletePeriod)
    }
    if deleteRemoteBranchWithWorktree != false {
      try container.encode(deleteRemoteBranchWithWorktree, forKey: .deleteRemoteBranchWithWorktree)
    }
  }
}
