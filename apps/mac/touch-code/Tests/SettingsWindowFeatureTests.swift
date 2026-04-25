import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct SettingsWindowFeatureTests {
  @Test
  func selectionChangesArePersistedInState() async {
    let store = TestStore(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.selectionChanged(.notifications)) { $0.selection = .notifications }
    await store.send(.selectionChanged(.about)) { $0.selection = .about }
  }

  @Test
  func windowClosedClearsSelection() async {
    let store = TestStore(
      initialState: SettingsWindowFeature.State(selection: .developer)
    ) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.windowClosed) { $0.selection = nil }
  }

  @Test
  func effectiveSectionFallsBackToGeneralWhenSelectionIsNil() {
    let empty = SettingsWindowFeature.State()
    #expect(empty.effectiveSection == .general)
    let withSelection = SettingsWindowFeature.State(selection: .updates)
    #expect(withSelection.effectiveSection == .updates)
  }

  @Test
  func projectsChangedPrunesStaleProjectGeneralSelection() async {
    let projectID = ProjectID()
    let store = TestStore(
      initialState: SettingsWindowFeature.State(selection: .projectGeneral(projectID))
    ) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    // Catalog no longer contains `projectID` — reducer must fall back to General.
    await store.send(.projectsChanged([])) { $0.selection = nil }
  }

  @Test
  func projectsChangedPrunesStaleProjectHooksSelection() async {
    let projectID = ProjectID()
    let store = TestStore(
      initialState: SettingsWindowFeature.State(selection: .projectHooks(projectID))
    ) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.projectsChanged([])) { $0.selection = nil }
  }

  @Test
  func projectsChangedKeepsSelectionWhenProjectStillExists() async {
    let projectID = ProjectID()
    let store = TestStore(
      initialState: SettingsWindowFeature.State(selection: .projectGeneral(projectID))
    ) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    // Catalog still holds `projectID` — no state change.
    await store.send(.projectsChanged([projectID]))
  }

  @Test
  func selectingProjectGeneralLazilyInstantiatesPane() async {
    let pid = ProjectID()
    let store = TestStore(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.kind = { _ in .gitRepo }
    }
    await store.send(.selectionChanged(.projectGeneral(pid))) {
      $0.selection = .projectGeneral(pid)
      $0.projectPanes.append(ProjectSettingsFeature.State(projectID: pid))
    }
    #expect(store.state.projectPanes[id: pid] != nil)
    #expect(store.state.projectPanes[id: pid]?.kind == .gitRepo)
  }

  @Test
  func selectingProjectHooksLazilyInstantiatesPane() async {
    let pid = ProjectID()
    let store = TestStore(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.kind = { _ in .plainDir }
    }
    await store.send(.selectionChanged(.projectHooks(pid))) {
      $0.selection = .projectHooks(pid)
      var expected = ProjectSettingsFeature.State(projectID: pid)
      expected.kind = .plainDir
      $0.projectPanes.append(expected)
    }
    #expect(store.state.projectPanes[id: pid] != nil)
    #expect(store.state.projectPanes[id: pid]?.kind == .plainDir)
  }

  @Test
  func reSelectingSameProjectPaneDoesNotDuplicateState() async {
    let pid = ProjectID()
    var initial = SettingsWindowFeature.State()
    initial.projectPanes.append(ProjectSettingsFeature.State(projectID: pid))
    let store = TestStore(initialState: initial) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.kind = { _ in .gitRepo }
    }
    await store.send(.selectionChanged(.projectGeneral(pid))) {
      $0.selection = .projectGeneral(pid)
    }
    #expect(store.state.projectPanes.count == 1)
  }

  @Test
  func selectingGlobalSectionDoesNotTouchProjectPanes() async {
    let store = TestStore(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.selectionChanged(.notifications)) {
      $0.selection = .notifications
    }
    #expect(store.state.projectPanes.isEmpty)
  }

  @Test
  func projectsChangedIgnoresGlobalSelection() async {
    let store = TestStore(
      initialState: SettingsWindowFeature.State(selection: .notifications)
    ) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    // Global selections are never pruned, even against an empty project set.
    await store.send(.projectsChanged([]))
  }
}
