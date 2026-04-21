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
    let snapshot = LegacyEditorSettings(
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
    let snapshot = LegacyEditorSettings(
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

  // MARK: - resolveDefault (T2 shared helper)

  @Test
  func resolveDefaultPrefersProjectOverride() {
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
    let resolved = EditorFeature.resolveDefault(
      projectOverride: "ghost-editor",
      globalDefault: "vscode",
      descriptors: Self.sampleDescriptors
    )
    #expect(resolved == .editor(Self.sampleDescriptors[0]))
  }

  @Test
  func resolveDefaultReturnsFinderWhenNothingResolves() {
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

  // MARK: - ⌘E default-editor resolution (T3)
  //
  // These TestStore cases prove that `.openDefaultInCurrentWorktreeRequested`
  // consumes the shared `resolveDefault` helper and forwards to `.openRequested`
  // with the expected editorID. Cascade semantics (e.g. missing override → global)
  // are exercised by the pure `resolveDefault*` tests above.

  private static func catalog(
    spaceID: SpaceID,
    projectID: ProjectID,
    worktreeID: WorktreeID,
    projectOverride: EditorID?
  ) -> Catalog {
    let worktree = Worktree(
      id: worktreeID, name: "w", path: "/w", branch: "main",
      tabs: [], selectedTabID: nil
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktreesDirectory: nil, defaultEditor: projectOverride,
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let space = Space(
      id: spaceID, name: "s", projects: [project], selectedProjectID: projectID
    )
    return Catalog(windows: [], spaces: [space], selectedSpaceID: spaceID)
  }

  private static func makeOpenStub() -> @Sendable (
    _ url: URL, _ editorID: EditorID?, _ projectID: ProjectID?
  ) async throws -> EditorChoice {
    { _, id, _ in
      let resolved = id ?? "finder"
      return EditorChoice(
        id: resolved,
        displayName: resolved.capitalized,
        binaryPath: URL(fileURLWithPath: "/usr/local/bin/\(resolved)"),
        argv: ["/usr/local/bin/\(resolved)", "/w"]
      )
    }
  }

  @Test
  func openDefaultInCurrentWorktreeWithInstalledOverrideForwardsOverride() async {
    // Positive case: project override "vscode" is present AND `.installed`.
    // resolve picks vscode over the configured globalDefault ("cursor").
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let snap = Self.catalog(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      projectOverride: "vscode"
    )

    var initial = EditorFeature.State()
    initial.descriptors = Self.sampleDescriptors
    initial.globalDefault = "cursor"

    let store = TestStore(initialState: initial) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = Self.makeOpenStub()
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { snap }
    }
    store.exhaustivity = .off
    await store.send(.openDefaultInCurrentWorktreeRequested(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      worktreePath: "/w"
    ))
    await store.receive(.openRequested(
      editorID: "vscode",
      worktreePath: "/w",
      projectID: projectID
    ))
  }

  @Test
  func openDefaultInCurrentWorktreeForwardsOverrideEvenIfUninstalled() async {
    // Documents the cascade-on-missing semantics from T2's resolveDefault:
    // an override that is present in `descriptors` but reports
    // `.missingBinary(...)` is still forwarded. The downstream
    // `.openRequested → EditorClient.open` surfaces the failure as a toast
    // rather than silently falling through to Finder. `sampleDescriptors`
    // ships cursor as the missing-binary descriptor.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let snap = Self.catalog(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      projectOverride: "cursor"
    )

    var initial = EditorFeature.State()
    initial.descriptors = Self.sampleDescriptors
    initial.globalDefault = "vscode"

    let store = TestStore(initialState: initial) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = Self.makeOpenStub()
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { snap }
    }
    store.exhaustivity = .off
    await store.send(.openDefaultInCurrentWorktreeRequested(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      worktreePath: "/w"
    ))
    await store.receive(.openRequested(
      editorID: "cursor",
      worktreePath: "/w",
      projectID: projectID
    ))
  }

  @Test
  func openDefaultInCurrentWorktreeFallsBackToGlobalDefault() async {
    // No override; globalDefault "vscode" present in descriptors → resolve picks vscode.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let snap = Self.catalog(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      projectOverride: nil
    )

    var initial = EditorFeature.State()
    initial.descriptors = Self.sampleDescriptors
    initial.globalDefault = "vscode"

    let store = TestStore(initialState: initial) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = Self.makeOpenStub()
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { snap }
    }
    store.exhaustivity = .off
    await store.send(.openDefaultInCurrentWorktreeRequested(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      worktreePath: "/w"
    ))
    await store.receive(.openRequested(
      editorID: "vscode",
      worktreePath: "/w",
      projectID: projectID
    ))
  }

  @Test
  func openDefaultInCurrentWorktreeFallsBackToFinder() async {
    // No override, no globalDefault → resolve returns .finder → forwards finder ID.
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let snap = Self.catalog(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      projectOverride: nil
    )

    var initial = EditorFeature.State()
    initial.descriptors = Self.sampleDescriptors
    let store = TestStore(initialState: initial) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient = EditorClient.testValue
      $0.editorClient.open = Self.makeOpenStub()
      $0.settingsWriter = SettingsWriter.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.hierarchyClient.snapshot = { snap }
    }
    store.exhaustivity = .off
    await store.send(.openDefaultInCurrentWorktreeRequested(
      spaceID: spaceID, projectID: projectID, worktreeID: worktreeID,
      worktreePath: "/w"
    ))
    await store.receive(.openRequested(
      editorID: EditorFeature.finderEditorID,
      worktreePath: "/w",
      projectID: projectID
    ))
  }
}
