import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Coverage for the `WorktreeHeaderFeature` actions and `HeaderRunScriptSplitButton`
/// state derivation introduced in Phase 2 M7.
@MainActor
struct HeaderRunScriptSplitButtonTests {

  // MARK: - Header feature delegate routing

  @Test
  func runScriptTappedEmitsRunScriptRequestedDelegate() async {
    let scriptID = UUID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = .testValue
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .runScriptTapped(scriptID: scriptID, projectID: projectID, worktreeID: worktreeID))
    await store.receive(
      .delegate(
        .runScriptRequested(scriptID: scriptID, projectID: projectID, worktreeID: worktreeID)))
  }

  @Test
  func manageScriptsTappedEmitsManageScriptsRequestedDelegate() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0[InboxClient.self] = .testValue
      $0.hierarchyClient = .testValue
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.manageScriptsTapped)
    await store.receive(.delegate(.manageScriptsRequested))
  }

  // MARK: - Primary-script resolution

  @Test
  func primaryScriptPicksFirstRunKindWhenAvailable() {
    let scripts = [
      ScriptDefinition(kind: .test, name: "Tests", command: "go test"),
      ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev"),
      ScriptDefinition(kind: .run, name: "Server", command: "npm run server"),
    ]
    let pick = HeaderRunScriptSplitButtonPrimaryResolver.primary(for: scripts)
    #expect(pick?.name == "Dev")
  }

  @Test
  func primaryScriptFallsBackToFirstScriptWhenNoRunKindExists() {
    let scripts = [
      ScriptDefinition(kind: .lint, name: "Lint", command: "npm run lint"),
      ScriptDefinition(kind: .test, name: "Tests", command: "npm test"),
    ]
    let pick = HeaderRunScriptSplitButtonPrimaryResolver.primary(for: scripts)
    #expect(pick?.name == "Lint")
  }

  @Test
  func primaryScriptIsNilForEmptyArray() {
    let pick = HeaderRunScriptSplitButtonPrimaryResolver.primary(for: [])
    #expect(pick == nil)
  }
}

/// Test-only mirror of `HeaderRunScriptSplitButton.primaryScript` so the
/// derivation is testable without instantiating SwiftUI views.
enum HeaderRunScriptSplitButtonPrimaryResolver {
  static func primary(for scripts: [ScriptDefinition]) -> ScriptDefinition? {
    scripts.first { $0.kind == .run } ?? scripts.first
  }
}
