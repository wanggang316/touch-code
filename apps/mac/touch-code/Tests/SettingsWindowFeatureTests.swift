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
}
