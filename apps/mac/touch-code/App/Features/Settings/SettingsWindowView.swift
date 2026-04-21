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
    .navigationTitle("Settings")
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

  @ViewBuilder
  private func detailView(for section: SettingsSection) -> some View {
    switch section {
    case .general:
      SettingsGeneralView(
        store: store.scope(state: \.general, action: \.general),
        settingsStore: settingsStore
      )
    case .notifications:
      NotificationsSettingsView()
    case .developer:
      DeveloperSettingsView()
    case .shortcuts:
      ComingSoonPane(title: "Shortcuts")
    case .updates:
      ComingSoonPane(title: "Updates")
    case .about:
      AboutSettingsView()
    case .repositoryGeneral(let projectID):
      RepositoryGeneralSettingsView(projectID: projectID)
    case .repositoryHooks(let projectID):
      RepositoryHooksSettingsView(projectID: projectID)
    }
  }
}
