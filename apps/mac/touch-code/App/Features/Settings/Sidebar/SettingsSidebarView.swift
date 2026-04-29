import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Settings window sidebar. Fixed-order global sections at the top, then a "Projects"
/// `Section` containing one `DisclosureGroup` per open Project (sorted by name). Each
/// disclosure exposes the Project's `General` and `Scripts` sub-rows. Kind itself is
/// **never** surfaced in the UI — no icon, no badge.
///
/// The Project list comes from the live `HierarchyManager` catalog; adding or removing a
/// Project in the main window reflects here without any explicit refresh (@Observable
/// subscription).
///
/// Disclosure open/close state lives in a local `@State` dictionary so Projects keep their
/// expansion across sidebar selection changes. This state is intentionally *not* persisted —
/// closing the window drops session state.
struct SettingsSidebarView: View {
  @Binding var selection: SettingsSection?
  @Environment(HierarchyManager.self) private var hierarchyManager
  @State private var expandedProjects: [ProjectID: Bool] = [:]

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(SettingsSection.globals, id: \.self) { section in
          globalRow(for: section)
            .tag(Optional(section))
        }
      }

      Section("Projects") {
        let projects = sortedProjects(in: hierarchyManager.catalog)
        if projects.isEmpty {
          Text("No open projects")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(projects) { project in
            projectDisclosure(project: project)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 180, ideal: 200)
  }

  // MARK: - Rows

  @ViewBuilder
  private func projectDisclosure(project: Project) -> some View {
    let binding = Binding<Bool>(
      get: { expandedProjects[project.id] ?? false },
      set: { expandedProjects[project.id] = $0 }
    )
    let subrows = SettingsSection.subrows(for: project.kind, projectID: project.id)
    DisclosureGroup(isExpanded: binding) {
      ForEach(subrows, id: \.self) { subrow in
        Label(subrow.projectSubrowTitle ?? "", systemImage: subrowIcon(for: subrow))
          .tag(Optional(subrow))
      }
    } label: {
      // A tap on the Project name selects its General pane when the disclosure is
      // currently collapsed (and expand it to reveal the sub-rows). `simultaneousGesture`
      // runs alongside DisclosureGroup's built-in label tap so the expansion toggle still
      // happens — we only add the selection write.
      Label(project.name, systemImage: "folder")
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .simultaneousGesture(
          TapGesture().onEnded {
            if !(expandedProjects[project.id] ?? false) {
              selection = .projectGeneral(project.id)
            }
          }
        )
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
    case .terminal: return "terminal"
    case .developer: return "hammer"
    case .shortcuts: return "command"
    case .updates: return "arrow.down.circle"
    case .about: return "info.circle"
    case .projectGeneral, .projectScripts:
      return ""
    }
  }

  /// Leading icon for Project sub-rows. Matches the global-section icon language where
  /// intuitive (Scripts → terminal) and drops to a blank for rows whose
  /// icon would add noise rather than signal.
  private func subrowIcon(for section: SettingsSection) -> String {
    switch section {
    case .projectGeneral: return "slider.horizontal.3"
    case .projectScripts: return "terminal"
    default: return ""
    }
  }
}
