import Foundation
import TouchCodeCore

/// One row in the Settings window sidebar. The global cases are fixed-order per spec M3
/// (with `.terminal` appended for the Ghostty theme / palette pane); the two Repository
/// cases carry the `ProjectID` they bind to and are surfaced under the sidebar's
/// "Repositories" DisclosureGroup. `SettingsWindowView` switches on this enum to decide
/// which pane to render in the detail column.
public enum SettingsSection: Hashable, Sendable {
  case general
  case github
  case notifications
  case terminal
  case developer
  case shortcuts
  case updates
  case about
  case repositoryGeneral(ProjectID)
  case repositoryHooks(ProjectID)

  /// Canonical iteration order for global sidebar rows (spec M3; GitHub appears between
  /// General and Notifications per exec-plan 0012 M6 wireframe).
  public static let globals: [SettingsSection] = [
    .general, .github, .notifications, .terminal, .developer, .shortcuts, .updates, .about,
  ]

  /// Display name for global sidebar rows. Repository cases return `nil` because their
  /// title needs a `ProjectID`→name resolution that only the window has access to;
  /// `SettingsWindowView` composes that string locally for the window-title binding.
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
    case .repositoryGeneral, .repositoryHooks: return nil
    }
  }
}
