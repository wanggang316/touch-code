import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct RepositorySettingsFeatureTests {
  // MARK: - setDefaultEditorOverride

  @Test
  func setDefaultEditorOverrideForwardsToSettingsWriter() async {
    let projectID = ProjectID()
    let captured = LockIsolated<(ProjectID, EditorID?)?>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { pid, eid in
        captured.setValue((pid, eid))
      }
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
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, eid in
        captured.setValue(.some(eid))
      }
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
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in }
    }

    await store.send(.setDefaultEditorOverride("xcode"))
    await store.receive(\.writeFailed) {
      $0.lastWriteFailure = nil
    }
  }

  // MARK: - setWorktreeBaseDirectory

  @Test
  func setWorktreeBaseDirectoryForwardsToSettingsWriter() async {
    let projectID = ProjectID()
    let captured = LockIsolated<(ProjectID, String?)?>(nil)
    let store = TestStore(initialState: RepositorySettingsFeature.State(projectID: projectID)) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectWorktreesDirectory = { pid, path in
        captured.setValue((pid, path))
      }
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
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectWorktreesDirectory = { _, path in
        captured.setValue(.some(path))
      }
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
  func onHooksAppearTagsProjectPathGlobMatchingRepoRootAsRepository() async {
    // hooks.json v2 added `.projectPathGlob` so users can scope a subscription to the
    // whole Project (any worktree / pane / tab / plain_dir root) directly. Match against
    // `project.rootPath`. `worktreePathGlob` no longer probes the rootPath — users who
    // want repo-wide scope pick `.projectPathGlob` explicitly.
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
    let sub = HookSubscription(
      id: subID,
      event: .paneCreated,
      command: "echo test",
      scope: .projectPathGlob("/Users/me/proj")
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
  func onHooksAppearTagsProjectIDScopeAsRepository() async {
    // `.projectID` is the canonical way to scope to a single Project — matches regardless
    // of kind, so `plain_dir` Projects get first-class coverage too.
    let projectID = ProjectID()
    let subID = UUID()
    let project = Project(id: projectID, name: "P", rootPath: "/tmp/p", gitRoot: nil)
    let space = Space(id: SpaceID(), name: "S", projects: [project])
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: space.id)
    let sub = HookSubscription(
      id: subID,
      event: .paneCreated,
      command: "notify",
      scope: .projectID(projectID)
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
    await store.send(.onHooksAppear) { $0.hooksLoad = .loading }
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
