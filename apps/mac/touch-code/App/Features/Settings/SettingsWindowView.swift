import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root view for the Settings window scene. Two-column `NavigationSplitView` with the
/// sidebar (global sections + Repositories disclosure) on the left and a per-section detail
/// pane on the right. The detail switch is frozen — T2/T3/T4 replace only the individual
/// placeholder view bodies, never the switch cases here.
struct SettingsWindowView: View {
  @Bindable var store: StoreOf<SettingsWindowFeature>
  /// Strong reference to the store so Appearance / future pane writes route through the
  /// single-writer SettingsStore without TCA scoping churn. Injected at scene construction.
  let settingsStore: SettingsStore
  /// Read for the sidebar's Repositories disclosure + the B8 pruning subscription below.
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let selection = Binding<SettingsSection?>(
      get: { store.state.selection },
      set: { store.send(.selectionChanged($0)) }
    )
    NavigationSplitView {
      SettingsSidebarView(selection: selection)
    } detail: {
      detailView(for: store.state.effectiveSection)
    }
    .frame(minWidth: 750, minHeight: 500)
    .navigationTitle(title(for: store.state.effectiveSection))
    .onChange(of: projectIDs, initial: true) { _, current in
      // B8: when the catalog drops a Project the user is viewing, fall back to General.
      store.send(.projectsChanged(current))
    }
    .onDisappear {
      store.send(.windowClosed)
    }
  }

  /// Stable snapshot of the current Project IDs. `@Observable` catalog access re-evaluates
  /// this on every mutation; `onChange(of:)` dedupes equal values.
  private var projectIDs: Set<ProjectID> {
    Set(hierarchyManager.catalog.spaces.flatMap { $0.projects.map(\.id) })
  }

  /// Window-title binding. Global sections use `SettingsSection.globalTitle`; repository
  /// sections resolve the owning Project's name through the live `HierarchyManager`
  /// catalog and fall back to a bare section name when the project has been dropped
  /// mid-flight (B8 handoff — `onChange(of: projectIDs)` will swap the selection back
  /// to `.general` one frame later).
  private func title(for section: SettingsSection) -> String {
    if let globalTitle = section.globalTitle {
      return globalTitle
    }
    if let pid = section.projectID, let suffix = section.projectSubrowTitle {
      return projectTitle(for: pid, suffix: suffix)
    }
    return "Settings"
  }

  private func projectTitle(for projectID: ProjectID, suffix: String) -> String {
    let project = hierarchyManager.catalog.spaces
      .lazy
      .flatMap(\.projects)
      .first { $0.id == projectID }
    guard let project else { return suffix }
    return "\(project.name) — \(suffix)"
  }

  @ViewBuilder
  private func detailView(for section: SettingsSection) -> some View {
    switch section {
    case .general:
      SettingsGeneralView(
        store: store.scope(state: \.general, action: \.general),
        settingsStore: settingsStore
      )
    case .github:
      GitHubSettingsView(settingsStore: settingsStore)
    case .notifications:
      NotificationsSettingsView(settingsStore: settingsStore)
    case .terminal:
      SettingsTerminalView(store: store.scope(state: \.terminal, action: \.terminal))
    case .developer:
      DeveloperSettingsView()
    case .shortcuts:
      ComingSoonPane(title: "Shortcuts")
    case .updates:
      ComingSoonPane(title: "Updates")
    case .about:
      AboutSettingsView()
    case .projectGeneral(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectGeneralSettingsView(
          projectID: projectID,
          store: paneStore,
          descriptors: store.state.general.descriptors
        )
      } else {
        // State entry is lazily instantiated in `selectionChanged`; this arm is a
        // belt-and-suspenders placeholder for the single frame between a user click
        // landing and the reducer run finishing.
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .projectHooks(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectHooksSettingsView(projectID: projectID, store: paneStore)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .projectGit(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectGitSettingsView(projectID: projectID, store: paneStore)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .projectGitHub(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectGitHubSettingsView(projectID: projectID, store: paneStore)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .projectScripts(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectScriptsSettingsView(projectID: projectID, store: paneStore)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .projectEnv(let projectID):
      if let paneStore = store.scope(
        state: \.projectPanes[id: projectID],
        action: \.projectPanes[id: projectID]
      ) {
        ProjectEnvSettingsView(projectID: projectID, store: paneStore)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
