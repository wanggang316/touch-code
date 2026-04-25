import Foundation
import TouchCodeCore

/// One row in the Settings window sidebar. The global cases are fixed-order; the
/// Project-scoped cases carry the `ProjectID` they bind to and are surfaced under the
/// sidebar's "Projects" DisclosureGroup. Phase 2 collapsed the per-Project sub-panes
/// from six to three: `General` absorbs editor / shell / worktree / GitHub /
/// environment Sections (with kind-conditional Section rendering inside the pane);
/// `Scripts` and `Hooks` keep their own sub-rows. `SettingsWindowView` switches on
/// this enum to decide which pane to render in the detail column.
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

  /// Project-universal settings: editor, default shell, worktree (git-only),
  /// GitHub (git-only), environment variables. Sections render conditionally on
  /// `ProjectKind` inside `ProjectGeneralSettingsView`.
  case projectGeneral(ProjectID)
  /// User-defined scripts + worktree-lifecycle scripts (git-only Section).
  case projectScripts(ProjectID)
  /// Hook subscriptions tagged Global / Project; inline-editable rows.
  case projectHooks(ProjectID)

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
    case .projectGeneral, .projectScripts, .projectHooks:
      return nil
    }
  }

  /// Extracts the backing `ProjectID` from any Project-scoped case; `nil` for globals.
  public var projectID: ProjectID? {
    switch self {
    case .projectGeneral(let pid),
      .projectScripts(let pid),
      .projectHooks(let pid):
      return pid
    default:
      return nil
    }
  }
}

extension SettingsSection {
  /// Sub-rows rendered under a Project. Phase 2 returns the same three rows for both
  /// `gitRepo` and `plainDir` Projects — kind difference is now encoded as Section-level
  /// conditional rendering inside `ProjectGeneralSettingsView`, not as separate sub-rows.
  /// The `kind` parameter is preserved for future uses (and so callers do not need a
  /// signature change if the policy ever splits again).
  public static func subrows(for kind: ProjectKind, projectID: ProjectID) -> [SettingsSection] {
    _ = kind
    return [
      .projectGeneral(projectID),
      .projectScripts(projectID),
      .projectHooks(projectID),
    ]
  }

  /// Human-readable row title for a Project-scoped sub-pane. Used by the sidebar row
  /// builder. Returns `nil` for global sections.
  public var projectSubrowTitle: String? {
    switch self {
    case .projectGeneral: return "General"
    case .projectScripts: return "Scripts"
    case .projectHooks: return "Hooks"
    default: return nil
    }
  }
}
