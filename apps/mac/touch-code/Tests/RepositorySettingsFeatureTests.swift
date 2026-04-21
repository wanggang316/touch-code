import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct RepositorySettingsFeatureTests {
  private func makeTestStore(projectID: ProjectID = ProjectID()) -> StoreOf<RepositorySettingsFeature> {
    TestStore(
      initialState: RepositorySettingsFeature.State(projectID: projectID),
      reducer: { RepositorySettingsFeature() },
      withDependencies: { deps in
        deps.hierarchyClient = .testValue
        deps.hookConfigClient = .testValue
        deps.finderClient = .testValue
      }
    )
  }

  // MARK: - setDefaultEditorOverride tests

  @Test
  func setDefaultEditorOverrideCallsHierarchyClient() async {
    let projectID = ProjectID()
    let store = makeTestStore(projectID: projectID)
    var setEditorCalled = false
    var capturedProjectID: ProjectID?
    var capturedEditorID: EditorID?

    store.dependencies.hierarchyClient.setRepositoryDefaultEditor = { pid, eid in
      setEditorCalled = true
      capturedProjectID = pid
      capturedEditorID = eid
    }

    await store.send(.setDefaultEditorOverride("vscode"))
    #expect(setEditorCalled)
    #expect(capturedProjectID == projectID)
    #expect(capturedEditorID == "vscode")
  }

  @Test
  func setDefaultEditorOverrideClearsOverrideWhenPassedNil() async {
    let projectID = ProjectID()
    let store = makeTestStore(projectID: projectID)
    var capturedEditorID: EditorID??  = .some(.some("initial"))

    store.dependencies.hierarchyClient.setRepositoryDefaultEditor = { _, eid in
      capturedEditorID = eid
    }

    await store.send(.setDefaultEditorOverride(nil))
    #expect(capturedEditorID == nil)
  }

  @Test
  func setDefaultEditorOverrideSetsClearsLastWriteFailureOnSuccess() async {
    let store = makeTestStore()
    store.dependencies.hierarchyClient.setRepositoryDefaultEditor = { _, _ in
      // Success — no throw
    }

    store.state.lastWriteFailure = "previous error"
    await store.send(.setDefaultEditorOverride("xcode")) {
      $0.lastWriteFailure = nil
    }
  }

  @Test
  func setDefaultEditorOverrideSetsLastWriteFailureOnError() async {
    let store = makeTestStore()
    struct TestError: Error { let message: String }
    let testError = TestError(message: "test write failed")

    store.dependencies.hierarchyClient.setRepositoryDefaultEditor = { _, _ in
      throw testError
    }

    await store.send(.setDefaultEditorOverride("xcode")) {
      $0.lastWriteFailure = String(describing: testError)
    }
  }

  // MARK: - setWorktreeBaseDirectory tests

  @Test
  func setWorktreeBaseDirectoryCallsHierarchyClient() async {
    let projectID = ProjectID()
    let store = makeTestStore(projectID: projectID)
    var setPathCalled = false
    var capturedProjectID: ProjectID?
    var capturedPath: String?

    store.dependencies.hierarchyClient.setRepositoryWorktreeBaseDirectory = { pid, path in
      setPathCalled = true
      capturedProjectID = pid
      capturedPath = path
    }

    await store.send(.setWorktreeBaseDirectory("/Users/me/worktrees"))
    #expect(setPathCalled)
    #expect(capturedProjectID == projectID)
    #expect(capturedPath == "/Users/me/worktrees")
  }

  @Test
  func setWorktreeBaseDirectoryClearsOverrideWhenPassedNil() async {
    let projectID = ProjectID()
    let store = makeTestStore(projectID: projectID)
    var capturedPath: String??  = .some(.some("/some/path"))

    store.dependencies.hierarchyClient.setRepositoryWorktreeBaseDirectory = { _, path in
      capturedPath = path
    }

    await store.send(.setWorktreeBaseDirectory(nil))
    #expect(capturedPath == nil)
  }

  // MARK: - onHooksAppear and hooksLoaded tests

  @Test
  func onHooksAppearSetsLoadingState() async {
    let store = makeTestStore()
    store.dependencies.hookConfigClient.load = {
      HookConfig(subscriptions: [])
    }

    await store.send(.onHooksAppear) {
      $0.hooksLoad = .loading
    }
  }

  @Test
  func onHooksAppearLoadsHooksAndClassifiesToRepository() async {
    let projectID = ProjectID()
    let wtree = Worktree(
      id: WorktreeID(),
      name: "main",
      path: "/path/to/wt",
      branch: "main"
    )
    let project = Project(
      id: projectID,
      name: "test",
      rootPath: "/root",
      gitRoot: "/root",
      worktrees: [wtree],
      defaultEditor: nil,
      worktreesDirectory: nil
    )
    let space = Space(id: SpaceID(), name: "space", projects: [project])
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: space.id)

    let subscription = HookSubscription(
      event: .gitPush,
      command: "echo test",
      scope: .worktreeID(wtree.id)  // Repository-scoped
    )

    let store = makeTestStore(projectID: projectID)
    store.dependencies.hookConfigClient.load = {
      HookConfig(subscriptions: [subscription])
    }
    store.dependencies.hierarchyClient.snapshot = { catalog }

    // Simulate successful load and classification.
    let hookRow = HookRow(
      id: subscription.id,
      event: subscription.event.rawValue,
      command: subscription.command,
      scope: subscription.scope.debugDescription,
      source: .repository
    )

    await store.send(.onHooksAppear) {
      $0.hooksLoad = .loading
    }

    await store.receive(.hooksLoaded(.success([hookRow]))) {
      $0.hooksLoad = .loaded([hookRow])
    }
  }

  @Test
  func onHooksAppearClassifiesToGlobalWhenScopeDoesNotMatch() async {
    let projectID = ProjectID()
    let project = Project(
      id: projectID,
      name: "test",
      rootPath: "/root",
      gitRoot: "/root"
    )
    let space = Space(id: SpaceID(), name: "space", projects: [project])
    let catalog = Catalog(windows: [], spaces: [space], selectedSpaceID: space.id)

    let subscription = HookSubscription(
      event: .gitPush,
      command: "echo test",
      scope: .anyPanel  // Global scope
    )

    let store = makeTestStore(projectID: projectID)
    store.dependencies.hookConfigClient.load = {
      HookConfig(subscriptions: [subscription])
    }
    store.dependencies.hierarchyClient.snapshot = { catalog }

    let hookRow = HookRow(
      id: subscription.id,
      event: subscription.event.rawValue,
      command: subscription.command,
      scope: subscription.scope.debugDescription,
      source: .global
    )

    await store.send(.onHooksAppear) {
      $0.hooksLoad = .loading
    }

    await store.receive(.hooksLoaded(.success([hookRow]))) {
      $0.hooksLoad = .loaded([hookRow])
    }
  }

  @Test
  func hooksLoadedFailureSetsFailedState() async {
    let store = makeTestStore()
    let errorMessage = "test load error"

    await store.send(.hooksLoaded(.failure(.loadFailed(errorMessage)))) {
      $0.hooksLoad = .failed(errorMessage)
    }
  }

  // MARK: - revealHooksJSONRequested tests

  @Test
  func revealHooksJSONRequestedCallsEnsureExistsThenReveal() async {
    let store = makeTestStore()
    var ensureExistsCalled = false
    var revealCalled = false
    var revealedPath: String?

    store.dependencies.hookConfigClient.ensureExists = {
      ensureExistsCalled = true
    }
    store.dependencies.finderClient.reveal = { path in
      revealCalled = true
      revealedPath = path
    }

    await store.send(.revealHooksJSONRequested)
    #expect(ensureExistsCalled)
    #expect(revealCalled)
    #expect(revealedPath == HookConfig.defaultURL().path)
  }

  @Test
  func revealHooksJSONRequestedSetsErrorOnEnsureExistsFailure() async {
    let store = makeTestStore()
    struct TestError: Error { let message: String }
    let testError = TestError(message: "ensure failed")

    store.dependencies.hookConfigClient.ensureExists = {
      throw testError
    }

    await store.send(.revealHooksJSONRequested) {
      $0.lastWriteFailure = String(describing: testError)
    }
  }

  // MARK: - writeFailed action tests

  @Test
  func writeFailedWithEmptyStringSetsNil() async {
    let store = makeTestStore()
    store.state.lastWriteFailure = "some error"

    await store.send(.writeFailed("")) {
      $0.lastWriteFailure = nil
    }
  }

  @Test
  func writeFailedWithMessageSetsMessage() async {
    let store = makeTestStore()
    let errorMessage = "connection failed"

    await store.send(.writeFailed(errorMessage)) {
      $0.lastWriteFailure = errorMessage
    }
  }
}

// MARK: - HookRow Helper (mock for testing)

nonisolated struct HookRow: Equatable, Identifiable {
  let id: UUID
  let event: String
  let command: String
  let scope: String
  let source: HookSource

  init(
    id: UUID,
    event: String,
    command: String,
    scope: String,
    source: HookSource
  ) {
    self.id = id
    self.event = event
    self.command = command
    self.scope = scope
    self.source = source
  }
}

// MARK: - HookRowBuilder Helper

enum HookRowBuilder {
  static func make(from subscription: HookSubscription, source: HookSource) -> HookRow {
    HookRow(
      id: subscription.id,
      event: subscription.event.rawValue,
      command: subscription.command,
      scope: subscription.scope.debugDescription,
      source: source
    )
  }
}

// MARK: - HookSource and HookEvent extensions

enum HookSource: Equatable {
  case global
  case repository
}

extension HookSubscription.Scope {
  var debugDescription: String {
    switch self {
    case .anyPanel: return "anyPanel"
    case .panelID(let id): return "panelID(\(id.raw.uuidString))"
    case .panelLabel(let label): return "panelLabel(\(label))"
    case .tabID(let id): return "tabID(\(id.raw.uuidString))"
    case .tabLabel(let label): return "tabLabel(\(label))"
    case .worktreeID(let id): return "worktreeID(\(id.raw.uuidString))"
    case .worktreePathGlob(let glob): return "worktreePathGlob(\(glob))"
    }
  }
}
