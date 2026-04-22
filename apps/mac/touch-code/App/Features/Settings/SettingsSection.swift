import Foundation
import TouchCodeCore

/// One row in the Settings window sidebar. The global cases are fixed-order per spec M3
/// (with `.terminal` appended for the Ghostty theme / palette pane); the two Repository
/// cases carry the `ProjectID` they bind to and are surfaced under the sidebar's
/// "Repositories" DisclosureGroup. `SettingsWindowView` switches on this enum to decide
/// which pane to render in the detail column.
public enum SettingsSection: Hashable, Sendable {
  case general
  case notifications
  case terminal
  case developer
  case shortcuts
  case updates
  case about
  case repositoryGeneral(ProjectID)
  case repositoryHooks(ProjectID)

  /// Canonical iteration order for global sidebar rows (spec M3).
  public static let globals: [SettingsSection] = [
    .general, .notifications, .terminal, .developer, .shortcuts, .updates, .about,
  ]
}
