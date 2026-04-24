import Foundation
import TouchCodeCore

/// One row in the Settings window sidebar. The global cases are fixed-order; the
/// Project-scoped cases carry the `ProjectID` they bind to and are surfaced under the
/// sidebar's "Projects" DisclosureGroup. The sidebar conditionally renders per-kind
/// sub-rows under each Project: `git_repo` exposes the git/GitHub panes, `plain_dir`
/// hides them. `SettingsWindowView` switches on this enum to decide which pane to
/// render in the detail column.
public enum SettingsSection: Hashable, Sendable {
  case general
  case github
  case notifications
  case terminal
  case developer
  case shortcuts
  case updates
  case about

  // MARK: - Project-scoped sub-panes

  /// Project-universal settings (editor override, worktree-dir override, shell, cwd).
  case projectGeneral(ProjectID)
  /// Git-kind-only: worktree base ref, copy-flags, worktrees directory.
  /// Rendered only when `project.kind == .gitRepo`.
  case projectGit(ProjectID)
  /// Git-kind-only: GitHub merge strategy, post-merge action, integration disable flag.
  /// Rendered only when `project.kind == .gitRepo`.
  case projectGitHub(ProjectID)
  /// User-defined scripts for this Project.
  case projectScripts(ProjectID)
  /// Hook subscriptions tagged Global / Project, read-only view.
  case projectHooks(ProjectID)
  /// Environment variables injected into new panes opened under this Project.
  case projectEnv(ProjectID)

  /// Canonical iteration order for global sidebar rows (GitHub appears between
  /// General and Notifications per earlier GitHub integration wireframe).
  public static let globals: [SettingsSection] = [
    .general, .github, .notifications, .terminal, .developer, .shortcuts, .updates, .about,
  ]

  /// Display name for global sidebar rows. Project-scoped cases return `nil` because
  /// their title needs a `ProjectID → name` resolution that only the window has access
  /// to; `SettingsWindowView` composes that string locally for the window-title binding.
  public var globalTitle: String? {
    switch self {
    case .general: return "General"
    case .github: return "GitHub"
    case .notifications: return "Notifications"
    case .terminal: return "Terminal"
    case .developer: return "Developer"
    case .shortcuts: return "Shortcuts"
    case .updates: return "Updates"
    case .about: return "About"
    case .projectGeneral, .projectGit, .projectGitHub, .projectScripts, .projectHooks, .projectEnv:
      return nil
    }
  }

  /// Extracts the backing `ProjectID` from any Project-scoped case; `nil` for globals.
  public var projectID: ProjectID? {
    switch self {
    case .projectGeneral(let pid),
      .projectGit(let pid),
      .projectGitHub(let pid),
      .projectScripts(let pid),
      .projectHooks(let pid),
      .projectEnv(let pid):
      return pid
    default:
      return nil
    }
  }
}

extension SettingsSection {
  /// Sub-rows rendered under a Project, keyed by `ProjectKind`. `.gitRepo` exposes the
  /// Git & Worktree and GitHub panes; `.plainDir` hides them (kind has no UI surface of
  /// its own — the available sub-rows are the only signal).
  public static func subrows(for kind: ProjectKind, projectID: ProjectID) -> [SettingsSection] {
    var rows: [SettingsSection] = [.projectGeneral(projectID)]
    if kind == .gitRepo {
      rows.append(.projectGit(projectID))
      rows.append(.projectGitHub(projectID))
    }
    rows.append(contentsOf: [
      .projectScripts(projectID),
      .projectHooks(projectID),
      .projectEnv(projectID),
    ])
    return rows
  }

  /// Human-readable row title for a Project-scoped sub-pane. Used by the sidebar row
  /// builder. Returns `nil` for global sections.
  public var projectSubrowTitle: String? {
    switch self {
    case .projectGeneral: return "General"
    case .projectGit: return "Git & Worktree"
    case .projectGitHub: return "GitHub"
    case .projectScripts: return "Scripts"
    case .projectHooks: return "Hooks"
    case .projectEnv: return "Environment"
    default: return nil
    }
  }
}
