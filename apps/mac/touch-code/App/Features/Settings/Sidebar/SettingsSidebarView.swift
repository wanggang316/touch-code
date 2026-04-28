import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Settings window sidebar. Fixed-order global sections at the top, then one
/// `Section` per open Project (sorted by name) carrying its sub-rows directly —
/// no DisclosureGroup chevron, the project name acts as the section header.
/// Sub-rows are `General`, `Scripts`, `Hooks`; kind difference (`git_repo` vs
/// `plain_dir`) is encoded as Section-level conditional rendering inside
/// `ProjectGeneralSettingsView`, never surfaced in the sidebar.
///
/// The Project list comes from the live `HierarchyManager` catalog; adding or
/// removing a Project in the main window reflects here without any explicit
/// refresh (@Observable subscription).
struct SettingsSidebarView: View {
  @Binding var selection: SettingsSection?
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(SettingsSection.globals, id: \.self) { section in
          globalRow(for: section)
            .tag(Optional(section))
        }
      }

      let projects = sortedProjects(in: hierarchyManager.catalog)
      if projects.isEmpty {
        Section("Projects") {
          Text("No open projects")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      } else {
        ForEach(projects) { project in
          projectSection(for: project)
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
  }

  // MARK: - Rows

  @ViewBuilder
  private func projectSection(for project: Project) -> some View {
    let subrows = SettingsSection.subrows(for: project.kind, projectID: project.id)
    Section(project.name) {
      ForEach(subrows, id: \.self) { subrow in
        Label(subrow.projectSubrowTitle ?? "", systemImage: subrowIcon(for: subrow))
          .tag(Optional(subrow))
      }
    }
  }

  // MARK: - Helpers

  private func sortedProjects(in catalog: Catalog) -> [Project] {
    catalog.projects
      .sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  /// Per-section sidebar row. GitHub uses the official mark from the bundled
  /// `github` asset (template-rendered SVG); every other row falls through to an
  /// SF Symbol.
  @ViewBuilder
  private func globalRow(for section: SettingsSection) -> some View {
    let title = section.globalTitle ?? ""
    if section == .github {
      Label {
        Text(title)
      } icon: {
        Image("github")
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
      }
    } else {
      Label(title, systemImage: icon(for: section))
    }
  }

  private func icon(for section: SettingsSection) -> String {
    switch section {
    case .general: return "gearshape"
    case .github: return "arrow.triangle.pull"
    case .notifications: return "bell"
    case .terminal: return "terminal"
    case .developer: return "hammer"
    case .shortcuts: return "command"
    case .updates: return "arrow.down.circle"
    case .about: return "info.circle"
    case .projectGeneral, .projectScripts, .projectHooks:
      return ""
    }
  }

  /// Leading icon for Project sub-rows. Matches the global-section icon language where
  /// intuitive (Scripts → terminal, Hooks → link) and drops to a blank for rows whose
  /// icon would add noise rather than signal.
  private func subrowIcon(for section: SettingsSection) -> String {
    switch section {
    case .projectGeneral: return "slider.horizontal.3"
    case .projectScripts: return "terminal"
    case .projectHooks: return "link"
    default: return ""
    }
  }
}
