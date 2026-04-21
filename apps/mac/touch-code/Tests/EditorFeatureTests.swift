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

  @Test
  func setProjectOverrideFailureSurfacesReason() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.setDefaultEditor = { _, _, _ in
        throw HierarchyError.notFound("Project xyz")
      }
    }
    await store.send(.setProjectOverride(
      projectID: ProjectID(), spaceID: SpaceID(), editorID: "cursor"
    ))
    await store.receive(\.setProjectOverrideFailed) { state in
      state.lastProjectOverrideFailure = #"notFound("Project xyz")"#
    }
  }

  @Test
  func openRequestedSuccessDispatchesOpenSucceeded() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, _, _ in
        EditorChoice(
          id: "cursor",
          displayName: "Cursor",
          binaryPath: URL(fileURLWithPath: "/usr/local/bin/cursor"),
          argv: ["/usr/local/bin/cursor", "/tmp/worktree"]
        )
      }
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.openRequested(
      editorID: "cursor",
      worktreePath: "/tmp/worktree",
      projectID: ProjectID()
    ))
    await store.receive(\.openSucceeded) { state in
      state.lastOpenResult = .opened(editorID: "cursor", displayName: "Cursor")
    }
  }

  @Test
  func openRequestedFailureMapsEditorErrorToReason() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = { _, _, _ in
        throw EditorError.notInstalled(id: "zed", binary: "zed")
      }
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
    }
    await store.send(.openRequested(
      editorID: "zed",
      worktreePath: "/tmp/worktree",
      projectID: nil
    ))
    await store.receive(\.openFailed) { state in
      state.lastOpenResult = .failed(reason: "zed CLI (`zed`) not found on PATH")
    }
  }

  @Test
  func editorErrorDescriptionMapsEveryCase() {
    // Belt-and-suspenders coverage: make sure a new EditorError case doesn't silently fall
    // into `String(describing:)` via the default branch.
    #expect(EditorFeature.editorErrorDescription(.notInstalled(id: "vscode", binary: "code")) ==
            "vscode CLI (`code`) not found on PATH")
    #expect(EditorFeature.editorErrorDescription(.spawnFailed(reason: "ENOENT")) ==
            "Could not launch editor: ENOENT")
    #expect(EditorFeature.editorErrorDescription(.nonZeroExit(code: 1, stderr: "boom\n")) ==
            "boom")
    #expect(EditorFeature.editorErrorDescription(.timedOut) ==
            "Editor did not respond within 5 seconds")
    #expect(EditorFeature.editorErrorDescription(.badTemplate(id: "x", reason: "y")) ==
            "Bad template for ‘x’: y")
    #expect(EditorFeature.editorErrorDescription(.notADirectory(path: "/x")) ==
            "Not a directory: /x")
    #expect(EditorFeature.editorErrorDescription(.unresolvedWorktree) ==
            "No worktree resolved")
  }

  // MARK: - resolveDefault

  @Test
  func resolveDefaultPrefersProjectOverride() {
    // Override "cursor" present in descriptors -> .editor(cursor)
    let resolved = EditorFeature.resolveDefault(
      projectOverride: "cursor",
      globalDefault: "vscode",
      descriptors: Self.sampleDescriptors
    )
    #expect(resolved == .editor(Self.sampleDescriptors[1]))
  }

  @Test
  func resolveDefaultFallsBackToGlobalWhenNoOverride() {
    let resolved = EditorFeature.resolveDefault(
      projectOverride: nil,
      globalDefault: "vscode",
      descriptors: Self.sampleDescriptors
    )
    #expect(resolved == .editor(Self.sampleDescriptors[0]))
  }

  @Test
  func resolveDefaultCascadesThroughMissingOverrideToGlobal() {
    // Override references an id not in descriptors (e.g., custom editor
    // was removed). Cascade to the global default — matches the legacy
    // dropdown's behavior so the user doesn't get stranded on Finder.
    let resolved = EditorFeature.resolveDefault(
      projectOverride: "ghost-editor",
      globalDefault: "vscode",
      descriptors: Self.sampleDescriptors
    )
    #expect(resolved == .editor(Self.sampleDescriptors[0]))
  }

  @Test
  func resolveDefaultReturnsFinderWhenNothingResolves() {
    // Neither override nor global resolves to a descriptor.
    let noOverride = EditorFeature.resolveDefault(
      projectOverride: nil,
      globalDefault: nil,
      descriptors: Self.sampleDescriptors
    )
    #expect(noOverride == .finder)

    let bothMissing = EditorFeature.resolveDefault(
      projectOverride: "ghost",
      globalDefault: "also-ghost",
      descriptors: Self.sampleDescriptors
    )
    #expect(bothMissing == .finder)
  }
}
