import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// `.onMove(fromOffsets:toOffset:)` semantics: dragging row 0 onto
/// position 2 (the slot AFTER what was originally at index 1) yields
/// `[s1, s0, s2]` — Swift inserts BEFORE the destination index after
/// removing the source. Pin that ordering against the reducer's
/// `setProjectScripts` write.
@MainActor
struct ProjectScriptsSettingsViewReorderTests {

  @Test
  func reorderRow0ToOffset2YieldsSwiftMoveSemantics() async {
    let projectID = ProjectID()
    let s0 = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let s1 = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let s2 = ScriptDefinition(kind: .lint, name: "Lint", command: "npm run lint")

    var reordered = [s0, s1, s2]
    reordered.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
    // Pin the canonical Swift result so the test cannot drift if the
    // pane wires `.onMove` differently.
    #expect(reordered.map(\.id) == [s1.id, s0.id, s2.id])

    let captured = LockIsolated<(ProjectID, [ScriptDefinition])?>(nil)
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectScripts = { pid, scripts in
        captured.setValue((pid, scripts))
      }
    }

    await store.send(.setProjectScripts(reordered))
    await store.receive(\.writeFailed)
    #expect(captured.value?.0 == projectID)
    #expect(captured.value?.1.map(\.id) == [s1.id, s0.id, s2.id])
  }
}
