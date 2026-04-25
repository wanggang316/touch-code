import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// `runScriptTapped` should invoke `HierarchyClient.runScript` with the
/// scriptID / projectID / worktreeID supplied by the row. Failures map
/// to `.writeFailed` so the pane's existing banner surfaces them.
@MainActor
struct ProjectScriptsSettingsViewRunButtonTests {

  @Test
  func runScriptTappedDispatchesHierarchyClient() async {
    let projectID = ProjectID()
    let scriptID = UUID()
    let worktreeID = WorktreeID()
    let captured = LockIsolated<(UUID, ProjectID, WorktreeID)?>(nil)

    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.runScript = { sid, pid, wid in
        captured.setValue((sid, pid, wid))
      }
    }

    await store.send(.runScriptTapped(scriptID: scriptID, worktreeID: worktreeID))
    await store.finish()

    #expect(captured.value?.0 == scriptID)
    #expect(captured.value?.1 == projectID)
    #expect(captured.value?.2 == worktreeID)
  }

  @Test
  func runScriptUnknownScriptSurfacesFailureMessage() async {
    let projectID = ProjectID()
    let scriptID = UUID()
    let worktreeID = WorktreeID()
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.runScript = { _, _, _ in
        throw RunScriptError.unknownScript(scriptID)
      }
    }

    await store.send(.runScriptTapped(scriptID: scriptID, worktreeID: worktreeID))
    await store.receive(\.writeFailed) {
      $0.lastWriteFailure = ProjectSettingsFeature.runScriptErrorMessage(.unknownScript(scriptID))
    }
  }

  @Test
  func runScriptErrorMessageMapsEachCase() {
    let pid = ProjectID()
    let wid = WorktreeID()
    let sid = UUID()
    #expect(
      ProjectSettingsFeature.runScriptErrorMessage(.unknownScript(sid))
        == "That script no longer exists."
    )
    #expect(
      ProjectSettingsFeature.runScriptErrorMessage(.missingWorktree(wid))
        == "The worktree for this script is no longer available."
    )
    #expect(
      ProjectSettingsFeature.runScriptErrorMessage(.missingProject(pid))
        == "The Project for this script is no longer available."
    )
  }
}
