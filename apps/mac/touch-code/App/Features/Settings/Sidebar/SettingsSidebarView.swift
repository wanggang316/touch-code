import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Settings window sidebar. Fixed-order global sections at the top (spec M3), then a
/// "Repositories" `Section` containing one `DisclosureGroup` per open Project (sorted by
/// name per spec M9). Each disclosure holds two rows — General and Hooks — that map to
/// `.repositoryGeneral(projectID)` / `.repositoryHooks(projectID)`.
///
/// The Project list comes from the live `HierarchyManager` catalog; adding or removing a
/// Project in the main window reflects here without any explicit refresh (@Observable
/// subscription), satisfying spec "sidebar immediately reflects Project add/remove".
///
/// Disclosure open/close state lives in a local `@State` dictionary so Projects keep their
/// expansion across sidebar selection changes. This state is intentionally *not* persisted —
/// spec M16 asks that closing the window drop session state.
struct SettingsSidebarView: View {
  @Binding var selection: SettingsSection?
  @Environment(HierarchyManager.self) private var hierarchyManager
  @State private var expandedProjects: [ProjectID: Bool] = [:]

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(SettingsSection.globals, id: \.self) { section in
          Label(title(for: section), systemImage: icon(for: section))
            .tag(Optional(section))
        }
      }

      Section("Repositories") {
        let projects = sortedProjects(in: hierarchyManager.catalog)
        if projects.isEmpty {
          Text("No open projects")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(projects) { project in
            repositoryDisclosure(project: project)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
  }

  // MARK: - Rows

  @ViewBuilder
  private func repositoryDisclosure(project: Project) -> some View {
    let binding = Binding<Bool>(
      get: { expandedProjects[project.id] ?? false },
      set: { expandedProjects[project.id] = $0 }
    )
    DisclosureGroup(isExpanded: binding) {
      Label("General", systemImage: "slider.horizontal.3")
        .tag(Optional(SettingsSection.repositoryGeneral(project.id)))
      Label("Hooks", systemImage: "link")
        .tag(Optional(SettingsSection.repositoryHooks(project.id)))
    } label: {
      // Spec M10: a tap on the Repository name should select its General pane when the
      // disclosure is currently collapsed (and expand it to reveal the two child rows).
      // `simultaneousGesture` runs alongside DisclosureGroup's built-in label tap so the
      // expansion toggle still happens — we only add the selection write.
      Label(project.name, systemImage: "folder")
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .simultaneousGesture(
          TapGesture().onEnded {
            if !(expandedProjects[project.id] ?? false) {
              selection = .repositoryGeneral(project.id)
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

  private func title(for section: SettingsSection) -> String {
    switch section {
    case .general: return "General"
    case .notifications: return "Notifications"
    case .terminal: return "Terminal"
    case .developer: return "Developer"
    case .shortcuts: return "Shortcuts"
    case .updates: return "Updates"
    case .about: return "About"
    case .repositoryGeneral, .repositoryHooks: return ""
    }
  }

  private func icon(for section: SettingsSection) -> String {
    switch section {
    case .general: return "gearshape"
    case .notifications: return "bell"
    case .terminal: return "terminal"
    case .developer: return "hammer"
    case .shortcuts: return "command"
    case .updates: return "arrow.down.circle"
    case .about: return "info.circle"
    case .repositoryGeneral, .repositoryHooks: return ""
    }
  }
}
