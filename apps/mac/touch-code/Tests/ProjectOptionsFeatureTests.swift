import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct ProjectOptionsFeatureTests {
  private static func makeState(
    name: String = "old-name",
    editor: EditorID? = nil,
    worktreesDirectory: String? = nil
  ) -> ProjectOptionsFeature.State {
    ProjectOptionsFeature.State(
      targetProjectID: ProjectID(),
      originalName: name,
      originalDefaultEditor: editor,
      originalWorktreesDirectory: worktreesDirectory,
      nameDraft: name,
      defaultEditorDraft: editor,
      worktreesDirectoryDraft: worktreesDirectory ?? ""
    )
  }

  @Test
  func saveFansOutAllThreeSettersWhenEverythingChanged() async {
    let renameCalls = LockIsolated<[(ProjectID, String)]>([])
    let editorCalls = LockIsolated<[(ProjectID, EditorID?)]>([])
    let worktreeDirCalls = LockIsolated<[(ProjectID, String?)]>([])

    var state = Self.makeState(name: "orig", editor: nil, worktreesDirectory: nil)
    state.nameDraft = "New Name"
    state.defaultEditorDraft = "cursor"
    state.worktreesDirectoryDraft = "/custom/dir"

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.hierarchyClient.renameProject = { pid, name in
        renameCalls.withValue { $0.append((pid, name)) }
      }
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { pid, editor in
        editorCalls.withValue { $0.append((pid, editor)) }
      }
      $0.settingsWriter.setProjectWorktreesDirectory = { pid, path in
        worktreeDirCalls.withValue { $0.append((pid, path)) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.saveTapped)
    await store.receive(\.delegate.saved)
    await store.receive(\.delegate.dismiss)

    #expect(renameCalls.value.count == 1)
    #expect(renameCalls.value.first?.1 == "New Name")
    #expect(editorCalls.value.count == 1)
    #expect(editorCalls.value.first?.1 == "cursor")
    #expect(worktreeDirCalls.value.count == 1)
    #expect(worktreeDirCalls.value.first?.1 == "/custom/dir")
  }

  @Test
  func saveSkipsRenameWhenNameUnchanged() async {
    let renameCallCount = LockIsolated(0)

    let state = Self.makeState(name: "same")

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.hierarchyClient.renameProject = { _, _ in
        renameCallCount.withValue { $0 += 1 }
      }
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in }
      $0.settingsWriter.setProjectWorktreesDirectory = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.saveTapped)
    await store.receive(\.delegate.saved)
    await store.receive(\.delegate.dismiss)

    #expect(renameCallCount.value == 0)
  }

  @Test
  func saveWithBlankNameKeepsSheetOpenAndSkipsCalls() async {
    let callCount = LockIsolated(0)
    var state = Self.makeState(name: "original")
    state.nameDraft = "   "

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.hierarchyClient.renameProject = { _, _ in
        callCount.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.saveTapped) {
      $0.validationError = "Project name cannot be blank."
    }

    #expect(callCount.value == 0)
  }

  @Test
  func cancelEmitsDismissWithoutSaving() async {
    let callCount = LockIsolated(0)
    var state = Self.makeState(name: "orig")
    state.nameDraft = "New"

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.hierarchyClient.renameProject = { _, _ in
        callCount.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.cancelTapped)
    await store.receive(\.delegate.dismiss)
    #expect(callCount.value == 0)
  }

  @Test
  func whitespaceOnlyWorktreesDirectoryClearsOverride() async {
    // Regression guard: a whitespace-only draft (`"   "`) must map to `nil` (clear),
    // not to the literal whitespace string. Persisting the literal would break
    // `projectAddWorktreeTapped` which treats the stored value as an absolute filesystem
    // base; worktree creation would point at an invalid path.
    let worktreeDirCalls = LockIsolated<[String?]>([])
    var state = Self.makeState(name: "p", worktreesDirectory: "/custom/dir")
    state.worktreesDirectoryDraft = "   "

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in }
      $0.settingsWriter.setProjectWorktreesDirectory = { _, path in
        worktreeDirCalls.withValue { $0.append(path) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.saveTapped)
    await store.receive(\.delegate.saved)
    await store.receive(\.delegate.dismiss)

    #expect(worktreeDirCalls.value.count == 1)
    #expect(worktreeDirCalls.value.first == .some(nil))
  }

  @Test
  func emptyWorktreesDirectoryClearsOverride() async {
    let worktreeDirCalls = LockIsolated<[String?]>([])
    var state = Self.makeState(name: "p", worktreesDirectory: "/custom/dir")
    state.worktreesDirectoryDraft = ""

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in }
      $0.settingsWriter.setProjectWorktreesDirectory = { _, path in
        worktreeDirCalls.withValue { $0.append(path) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.saveTapped)
    await store.receive(\.delegate.saved)
    await store.receive(\.delegate.dismiss)

    // Empty-string draft normalises to nil in the reducer so the writer sees "clear".
    #expect(worktreeDirCalls.value.count == 1)
    #expect(worktreeDirCalls.value.first == .some(nil))
  }

  @Test
  func editorUnchangedSkipsSetDefaultEditor() async {
    let editorCallCount = LockIsolated(0)
    let state = Self.makeState(name: "p", editor: "cursor")

    let store = TestStore(initialState: state) {
      ProjectOptionsFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in
        editorCallCount.withValue { $0 += 1 }
      }
      $0.settingsWriter.setProjectWorktreesDirectory = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.saveTapped)
    await store.receive(\.delegate.saved)
    await store.receive(\.delegate.dismiss)

    #expect(editorCallCount.value == 0)
  }
}
