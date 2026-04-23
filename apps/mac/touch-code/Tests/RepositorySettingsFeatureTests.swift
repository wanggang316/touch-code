import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct RepositorySettingsFeatureTests {
  // MARK: - setDefaultEditorOverride

  @Test
  func setDefaultEditorOverrideForwardsToHierarchyClient() async {
    let projectID = ProjectID()
    let captured = LockIsolated<(ProjectID, EditorID?)?>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.setRepositoryDefaultEditor = { pid, eid in
        captured.setValue((pid, eid))
      }
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.setDefaultEditorOverride("vscode"))
    await store.receive(\.writeFailed)
    #expect(captured.value?.0 == projectID)
    #expect(captured.value?.1 == "vscode")
  }

  @Test
  func setDefaultEditorOverridePassesNilForClearRequest() async {
    let captured = LockIsolated<EditorID??>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.setRepositoryDefaultEditor = { _, eid in
        captured.setValue(.some(eid))
      }
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.setDefaultEditorOverride(nil))
    await store.receive(\.writeFailed)
    #expect(captured.value == .some(nil))
  }

  @Test
  func setDefaultEditorOverrideClearsLastWriteFailureOnSuccess() async {
    var initial = RepositorySettingsFeature.State(projectID: ProjectID())
    initial.lastWriteFailure = "previous error"
    let store = TestStore(initialState: initial) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.setRepositoryDefaultEditor = { _, _ in }
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.setDefaultEditorOverride("xcode"))
    await store.receive(\.writeFailed) {
      $0.lastWriteFailure = nil
    }
  }

  @Test
  func setDefaultEditorOverrideStoresErrorMessageOnThrow() async {
    struct DummyError: Error, CustomStringConvertible { var description: String { "boom" } }
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.setRepositoryDefaultEditor = { _, _ in throw DummyError() }
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.setDefaultEditorOverride("xcode"))
    await store.receive(\.writeFailed) {
      $0.lastWriteFailure = "boom"
    }
  }

  // MARK: - setWorktreeBaseDirectory

  @Test
  func setWorktreeBaseDirectoryForwardsToHierarchyClient() async {
    let projectID = ProjectID()
    let captured = LockIsolated<(ProjectID, String?)?>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.setRepositoryWorktreeBaseDirectory = { pid, path in
        captured.setValue((pid, path))
      }
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.setWorktreeBaseDirectory("/Users/me/worktrees"))
    await store.receive(\.writeFailed)
    #expect(captured.value?.0 == projectID)
    #expect(captured.value?.1 == "/Users/me/worktrees")
  }

  @Test
  func setWorktreeBaseDirectoryPassesNilForClearRequest() async {
    let captured = LockIsolated<String??>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.setRepositoryWorktreeBaseDirectory = { _, path in
        captured.setValue(.some(path))
      }
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.setWorktreeBaseDirectory(nil))
    await store.receive(\.writeFailed)
    #expect(captured.value == .some(nil))
  }

  // MARK: - onHooksAppear + classification

  @Test
  func onHooksAppearTagsRepositoryScopedSubscription() async {
    let projectID = ProjectID()
    let subID = UUID()
    let wtID = WorktreeID()
    let project = Project(
      id: projectID,
      name: "P",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [Worktree(id: wtID, name: "main", path: "/repo/main", branch: "main")]
    )
    let space = Space(id: SpaceID(), name: "S", projects: [project])
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: space.id)
    let sub = HookSubscription(
      id: subID,
      event: .paneCreated,
      command: "echo test",
      scope: .worktreeID(wtID)
    )

    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.load = { HookConfig(subscriptions: [sub]) }
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { catalog }
      $0.finderClient = .testValue
    }

    let expected = HookRowBuilder.make(from: sub, source: .repository)
    await store.send(.onHooksAppear) {
      $0.hooksLoad = .loading
    }
    await store.receive(\.hooksLoaded.success) {
      $0.hooksLoad = .loaded([expected])
    }
  }

  @Test
  func onHooksAppearTagsWorktreePathGlobMatchingProjectRootAsRepository() async {
    // B4 regression guard: worktreePathGlob targeting the repo root must tag as
    // Repository even when no `worktrees` entry's path matches. Design's Data
    // Storage § Hook classification requires project.rootPath to be checked too.
    let projectID = ProjectID()
    let subID = UUID()
    let project = Project(
      id: projectID,
      name: "P",
      rootPath: "/Users/me/proj",
      gitRoot: "/Users/me/proj",
      worktrees: [
        Worktree(id: WorktreeID(), name: "feat-a", path: "/Users/me/wts/feat-a", branch: "a")
      ]
    )
    let space = Space(id: SpaceID(), name: "S", projects: [project])
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: space.id)
    // Glob matches project.rootPath exactly but does NOT match /Users/me/wts/feat-a.
    let sub = HookSubscription(
      id: subID,
      event: .paneCreated,
      command: "echo test",
      scope: .worktreePathGlob("/Users/me/proj")
    )

    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.load = { HookConfig(subscriptions: [sub]) }
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { catalog }
      $0.finderClient = .testValue
    }

    let expected = HookRowBuilder.make(from: sub, source: .repository)
    await store.send(.onHooksAppear) {
      $0.hooksLoad = .loading
    }
    await store.receive(\.hooksLoaded.success) {
      $0.hooksLoad = .loaded([expected])
    }
  }

  @Test
  func onHooksAppearTagsGlobalScopedSubscriptionAsGlobal() async {
    let projectID = ProjectID()
    let subID = UUID()
    let project = Project(id: projectID, name: "P", rootPath: "/repo", gitRoot: "/repo")
    let space = Space(id: SpaceID(), name: "S", projects: [project])
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: space.id)
    let sub = HookSubscription(
      id: subID,
      event: .paneCreated,
      command: "echo test",
      scope: .anyPane
    )

    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.load = { HookConfig(subscriptions: [sub]) }
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { catalog }
      $0.finderClient = .testValue
    }

    let expected = HookRowBuilder.make(from: sub, source: .global)
    await store.send(.onHooksAppear) {
      $0.hooksLoad = .loading
    }
    await store.receive(\.hooksLoaded.success) {
      $0.hooksLoad = .loaded([expected])
    }
  }

  // MARK: - revealHooksJSONRequested

  @Test
  func revealHooksJSONRequestedCallsEnsureExistsThenReveal() async {
    let ensureCalled = LockIsolated(false)
    let revealed = LockIsolated<String?>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.ensureExists = { ensureCalled.setValue(true) }
      $0.finderClient = .testValue
      $0.finderClient.reveal = { path in revealed.setValue(path) }
      $0.hierarchyClient = .testValue
    }

    await store.send(.revealHooksJSONRequested)
    await store.finish()
    #expect(ensureCalled.value)
    #expect(revealed.value == HookConfig.defaultURL().path)
  }

  @Test
  func revealHooksJSONRequestedSurfacesEnsureExistsFailure() async {
    struct DummyError: Error, CustomStringConvertible { var description: String { "ensure boom" } }
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.ensureExists = { throw DummyError() }
      $0.finderClient = .testValue
      $0.hierarchyClient = .testValue
    }

    await store.send(.revealHooksJSONRequested)
    await store.receive(\.writeFailed) {
      $0.lastWriteFailure = "ensure boom"
    }
  }

  // MARK: - writeFailed

  @Test
  func writeFailedEmptyStringClearsError() async {
    var initial = RepositorySettingsFeature.State(projectID: ProjectID())
    initial.lastWriteFailure = "something"
    let store = TestStore(initialState: initial) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.writeFailed("")) {
      $0.lastWriteFailure = nil
    }
  }

  @Test
  func writeFailedNonEmptyRecordsMessage() async {
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.writeFailed("io error")) {
      $0.lastWriteFailure = "io error"
    }
  }

  @Test
  func hooksLoadedFailureSetsFailedState() async {
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: ProjectID())) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
    }

    let err = RepositorySettingsFeature.LoadError.loadFailed("disk gone")
    await store.send(.hooksLoaded(.failure(err))) {
      $0.hooksLoad = .failed(String(describing: err))
    }
  }
}
