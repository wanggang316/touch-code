import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore
@testable import touch_code

@MainActor
struct EditorFeatureTests {
  // MARK: - Fixtures

  nonisolated static let sampleDescriptors: [EditorDescriptor] = [
    EditorDescriptor(
      id: "vscode",
      displayName: "Visual Studio Code",
      origin: .builtin,
      template: CommandTemplate(binary: "code", args: ["{dir}"]),
      installation: .installed(resolvedBinary: URL(fileURLWithPath: "/usr/local/bin/code"))
    ),
    EditorDescriptor(
      id: "cursor",
      displayName: "Cursor",
      origin: .builtin,
      template: CommandTemplate(binary: "cursor", args: ["{dir}"]),
      installation: .missingBinary(expected: "cursor")
    ),
  ]

  // MARK: - Tests

  @Test
  func onAppearFetchesDescriptors() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient.describe = { Self.sampleDescriptors }
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.readSnapshot = { .default }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    store.exhaustivity = .off
    await store.send(.onAppear)
    await store.receive(\.descriptorsLoaded) { state in
      state.descriptors = Self.sampleDescriptors
    }
  }

  @Test
  func onAppearObservesSettings() async {
    let snapshot = Settings(
      defaultEditorID: "vscode",
      customEditors: [
        CustomEditor(
          id: "helix",
          displayName: "Helix",
          template: CommandTemplate(binary: "hx", args: ["{dir}"])
        )
      ]
    )
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient.describe = { [] }
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.readSnapshot = { snapshot }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    store.exhaustivity = .off
    await store.send(.onAppear)
    await store.receive(\.settingsObserved) { state in
      state.globalDefault = "vscode"
      state.customEditors = snapshot.customEditors
    }
  }

  @Test
  func setGlobalDefaultWritesThroughSettingsWriter() async {
    let writtenID = LockIsolated<EditorID?>(nil)
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.setDefaultEditorID = { id in writtenID.setValue(id) }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.setGlobalDefault("zed")) {
      $0.globalDefault = "zed"
    }
    await store.finish()
    #expect(writtenID.value == "zed")
  }

  @Test
  func addCustomEditorSuccessRefreshesObservedSettings() async {
    let snapshot = Settings(
      defaultEditorID: nil,
      customEditors: [
        CustomEditor(
          id: "helix",
          displayName: "Helix",
          template: CommandTemplate(binary: "hx", args: ["{dir}"])
        )
      ]
    )
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.addCustomEditor = { _ in .success(()) }
      $0.settingsWriter.readSnapshot = { snapshot }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    let helix = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    await store.send(.addCustomEditor(helix))
    await store.receive(\.settingsObserved) {
      $0.customEditors = snapshot.customEditors
    }
  }

  @Test
  func addCustomEditorFailureSurfacesValidationError() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.addCustomEditor = { _ in .failure(.invalidID("vscode")) }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    let colliding = CustomEditor(
      id: "vscode",
      displayName: "Bad",
      template: CommandTemplate(binary: "code-insiders", args: ["{dir}"])
    )
    await store.send(.addCustomEditor(colliding))
    await store.receive(\.addCustomEditorFailed) {
      $0.lastValidationError = .invalidID("vscode")
    }
  }

  @Test
  func removeCustomEditorUpdatesStateAndInvokesWriter() async {
    var initial = EditorFeature.State()
    let helix = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "hx", args: ["{dir}"])
    )
    initial.customEditors = [helix]

    let removedID = LockIsolated<EditorID?>(nil)
    let store = TestStore(initialState: initial) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.removeCustomEditor = { id in removedID.setValue(id) }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.removeCustomEditor(id: "helix")) {
      $0.customEditors = []
    }
    await store.finish()
    #expect(removedID.value == "helix")
  }

  @Test
  func setProjectOverrideCallsHierarchyClient() async {
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let recorded = LockIsolated<(ProjectID, SpaceID, EditorID?)?>(nil)
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.setDefaultEditor = { pid, sid, eid in
        recorded.setValue((pid, sid, eid))
      }
    }
    await store.send(.setProjectOverride(
      projectID: projectID, spaceID: spaceID, editorID: "cursor"
    ))
    await store.finish()
    #expect(recorded.value?.0 == projectID)
    #expect(recorded.value?.1 == spaceID)
    #expect(recorded.value?.2 == "cursor")
  }
}
