import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct AddProjectFeatureTests {
  // MARK: - Fixtures

  /// Creates a `file://` URL under the process's temp directory. Optionally
  /// initializes it as a git repo so the add-time `discoverGitRoot` classifies
  /// the folder as git-backed.
  private static func makeTempDir(gitInit: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pm-addproject-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if gitInit {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["init", "--quiet"]
      process.currentDirectoryURL = url
      try process.run()
      process.waitUntilExit()
    }
    return url
  }

  private static func removeTemp(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Tests

  @Test
  func happyPathGitFolderSubmits() async throws {
    let dir = try Self.makeTempDir(gitInit: true)
    defer { Self.removeTemp(dir) }
    let canonical = HierarchyManager.canonicalPath(dir.path)
    let spaceID = SpaceID()
    let addedProjectID = ProjectID()
    let addCalls = LockIsolated<[(SpaceID, String, String, String?)]>([])

    let store = TestStore(
      initialState: AddProjectFeature.State(targetSpaceID: spaceID)
    ) {
      AddProjectFeature()
    } withDependencies: {
      $0.folderPickerClient.pick = { _ in dir }
      $0.hierarchyClient.isPathRegistered = { _ in nil }
      $0.hierarchyClient.addProject = { space, name, root, gitRoot in
        addCalls.withValue { $0.append((space, name, root, gitRoot)) }
        return addedProjectID
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.openPickerTapped)
    await store.receive(\.folderPicked)
    await store.receive(\.validationStarted)
    await store.receive(\.validationResolved)

    await store.send(.submitTapped)
    await store.receive(\.submitCompleted)
    await store.receive(\.delegate.projectAdded)
    await store.receive(\.delegate.dismiss)

    let captured = addCalls.value
    #expect(captured.count == 1)
    #expect(captured.first?.0 == spaceID)
    #expect(captured.first?.2 == canonical)
    #expect(captured.first?.3 != nil)  // gitRoot resolved
  }

  @Test
  func happyPathNonGitFolderSubmitsWithNilGitRoot() async throws {
    let dir = try Self.makeTempDir(gitInit: false)
    defer { Self.removeTemp(dir) }
    let spaceID = SpaceID()
    let addedProjectID = ProjectID()
    let capturedGitRoot = LockIsolated<String??>(nil)

    let store = TestStore(
      initialState: AddProjectFeature.State(targetSpaceID: spaceID)
    ) {
      AddProjectFeature()
    } withDependencies: {
      $0.folderPickerClient.pick = { _ in dir }
      $0.hierarchyClient.isPathRegistered = { _ in nil }
      $0.hierarchyClient.addProject = { _, _, _, gitRoot in
        capturedGitRoot.withValue { $0 = gitRoot }
        return addedProjectID
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.openPickerTapped)
    await store.receive(\.folderPicked)
    await store.receive(\.validationStarted)
    await store.receive(\.validationResolved)
    await store.send(.submitTapped)
    await store.receive(\.submitCompleted)
    await store.receive(\.delegate.projectAdded)
    await store.receive(\.delegate.dismiss)

    let inner = capturedGitRoot.value
    if case .some(let unwrapped) = inner {
      #expect(unwrapped == nil)  // non-git → gitRoot is nil
    } else {
      Issue.record("addProject was never invoked")
    }
  }

  @Test
  func duplicatePathBlocksSubmitAndEmitsRevealDelegate() async throws {
    let dir = try Self.makeTempDir(gitInit: true)
    defer { Self.removeTemp(dir) }
    let spaceID = SpaceID()
    let existingSpaceID = SpaceID()
    let existingProjectID = ProjectID()
    let addCallCount = LockIsolated(0)

    let store = TestStore(
      initialState: AddProjectFeature.State(targetSpaceID: spaceID)
    ) {
      AddProjectFeature()
    } withDependencies: {
      $0.folderPickerClient.pick = { _ in dir }
      $0.hierarchyClient.isPathRegistered = { _ in (existingSpaceID, existingProjectID) }
      $0.hierarchyClient.addProject = { _, _, _, _ in
        addCallCount.withValue { $0 += 1 }
        return ProjectID()
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.openPickerTapped)
    await store.receive(\.folderPicked) {
      $0.duplicate = AddProjectFeature.DuplicateRegistration(
        spaceID: existingSpaceID,
        projectID: existingProjectID
      )
    }

    // submit is a no-op because duplicate != nil.
    await store.send(.submitTapped)
    #expect(addCallCount.value == 0)

    // Reveal emits the delegate pair.
    await store.send(.revealExistingTapped)
    await store.receive(\.delegate.revealExisting)
    await store.receive(\.delegate.dismiss)
  }

  @Test
  func emptyNameDraftDisablesSubmit() async throws {
    let dir = try Self.makeTempDir(gitInit: true)
    defer { Self.removeTemp(dir) }
    let addCallCount = LockIsolated(0)

    let store = TestStore(
      initialState: AddProjectFeature.State(targetSpaceID: SpaceID())
    ) {
      AddProjectFeature()
    } withDependencies: {
      $0.folderPickerClient.pick = { _ in dir }
      $0.hierarchyClient.isPathRegistered = { _ in nil }
      $0.hierarchyClient.addProject = { _, _, _, _ in
        addCallCount.withValue { $0 += 1 }
        return ProjectID()
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.openPickerTapped)
    await store.receive(\.folderPicked)
    await store.receive(\.validationStarted)
    await store.receive(\.validationResolved)

    await store.send(.nameDraftChanged("   "))
    await store.send(.submitTapped)

    // Whitespace-only draft → canSubmit is false → addProject not called.
    #expect(addCallCount.value == 0)
  }

  @Test
  func cancelEmitsDismissDelegate() async {
    let store = TestStore(
      initialState: AddProjectFeature.State(targetSpaceID: SpaceID())
    ) {
      AddProjectFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.cancelTapped)
    await store.receive(\.delegate.dismiss)
  }

  @Test
  func pickerCancelledDismisses() async {
    let store = TestStore(
      initialState: AddProjectFeature.State(targetSpaceID: SpaceID())
    ) {
      AddProjectFeature()
    } withDependencies: {
      $0.folderPickerClient.pick = { _ in nil }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.openPickerTapped)
    await store.receive(\.folderPicked)
    await store.receive(\.delegate.dismiss)
  }
}
