import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Settings window sidebar. Fixed-order global sections at the top, then a "Projects"
/// `Section` containing one `DisclosureGroup` per open Project (sorted by name). Each
/// disclosure's sub-rows depend on the Project's `ProjectKind` (derived from `gitRoot`):
/// `git_repo` renders six sub-rows (General, Git & Worktree, GitHub, Scripts, Hooks,
/// Environment), `plain_dir` renders four (General, Scripts, Hooks, Environment). Kind
/// itself is **never** surfaced in the UI — no icon, no badge. The available sub-rows are
/// the only signal.
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
          Label(section.globalTitle ?? "", systemImage: icon(for: section))
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
    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
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
    catalog.spaces
      .flatMap(\.projects)
      .sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
    case .projectGeneral, .projectGit, .projectGitHub, .projectScripts, .projectHooks, .projectEnv:
      return ""
    }
  }

  /// Leading icon for Project sub-rows. Matches the global-section icon language where
  /// intuitive (Scripts → terminal, Hooks → link) and drops to a blank for rows whose
  /// icon would add noise rather than signal.
  private func subrowIcon(for section: SettingsSection) -> String {
    switch section {
    case .projectGeneral: return "slider.horizontal.3"
    case .projectGit: return "arrow.branch"
    case .projectGitHub: return "arrow.triangle.pull"
    case .projectScripts: return "terminal"
    case .projectHooks: return "link"
    case .projectEnv: return "leaf"
    default: return ""
    }
  }
}
