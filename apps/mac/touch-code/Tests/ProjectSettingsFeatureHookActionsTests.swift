import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Reducer coverage for `.upsertHook` and `.deleteHook`. Both forward
/// the payload to `HookConfigClient` and re-trigger `.onHooksAppear`
/// so the merged list refreshes on success. Failures dispatch
/// `.writeFailed(_:)` with the underlying error message.
@MainActor
struct ProjectSettingsFeatureHookActionsTests {
  /// Test error type to drive the failure paths through the typed
  /// `Error.localizedDescription` shape `.writeFailed` interpolates.
  struct DummyError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  @Test
  func upsertHookForwardsToClientAndReloads() async {
    let projectID = ProjectID()
    let captured = LockIsolated<HookSubscription?>(nil)
    let sub = HookSubscription(event: .paneReady, command: "echo hi")

    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = {
        let project = Project(id: projectID, name: "P", rootPath: "/p")
        return Catalog(projects: [project])
      }
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.upsert = { incoming in
        captured.setValue(incoming)
      }
      $0.hookConfigClient.load = { HookConfig(subscriptions: [sub]) }
      $0.finderClient = .testValue
    }
    store.exhaustivity = .off

    await store.send(.upsertHook(sub))
    await store.receive(\.onHooksAppear)

    #expect(captured.value?.id == sub.id)
    #expect(captured.value?.command == "echo hi")
  }

  @Test
  func upsertHookSurfacesFailureViaWriteFailed() async {
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: ProjectID())) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.upsert = { _ in
        throw DummyError(message: "kaboom")
      }
      $0.finderClient = .testValue
    }
    store.exhaustivity = .off

    let sub = HookSubscription(event: .paneReady, command: "echo")
    await store.send(.upsertHook(sub))
    await store.receive(\.writeFailed) { state in
      #expect(state.lastWriteFailure?.contains("kaboom") == true)
    }
  }

  @Test
  func deleteHookForwardsToClientAndReloads() async {
    let projectID = ProjectID()
    let captured = LockIsolated<UUID?>(nil)
    let id = UUID()

    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = {
        let project = Project(id: projectID, name: "P", rootPath: "/p")
        return Catalog(projects: [project])
      }
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.delete = { incoming in
        captured.setValue(incoming)
      }
      $0.hookConfigClient.load = { HookConfig() }
      $0.finderClient = .testValue
    }
    store.exhaustivity = .off

    await store.send(.deleteHook(id))
    await store.receive(\.onHooksAppear)

    #expect(captured.value == id)
  }

  @Test
  func deleteHookSurfacesFailureViaWriteFailed() async {
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: ProjectID())) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hookConfigClient = .testValue
      $0.hookConfigClient.delete = { _ in
        throw DummyError(message: "delete failed")
      }
      $0.finderClient = .testValue
    }
    store.exhaustivity = .off

    await store.send(.deleteHook(UUID()))
    await store.receive(\.writeFailed) { state in
      #expect(state.lastWriteFailure?.contains("delete failed") == true)
    }
  }
}
