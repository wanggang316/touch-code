import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

// TODO(C8a Phase 6): the C8 suite exercised the retired custom-editor surface
// (addCustomEditor / updateCustomEditor / removeCustomEditor, argv assertions, etc.).
// Phase 6 rebuilds this against the NSWorkspace-backed EditorService. Keeping a minimal
// smoke test here so the suite still reports to the build.
@MainActor
struct EditorFeatureTests {
  private nonisolated static let sampleDescriptor = EditorDescriptor(
    id: "vscode",
    displayName: "Visual Studio Code",
    bundleIdentifier: "com.microsoft.VSCode",
    launchMode: .directory,
    appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
    alternateBundleIdentifiers: []
  )

  @Test
  func onAppearFetchesDescriptors() async {
    let store = TestStore(initialState: EditorFeature.State()) {
      EditorFeature()
    } withDependencies: {
      $0.editorClient.describe = { [Self.sampleDescriptor] }
      $0.settingsWriter = SettingsWriter.testValue
      $0.settingsWriter.readSnapshot = { .default }
      $0.hierarchyClient = HierarchyClient.testValue
    }
    store.exhaustivity = .off
    await store.send(.onAppear)
    await store.receive(\.descriptorsLoaded) { state in
      state.descriptors = [Self.sampleDescriptor]
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
  func editorErrorDescriptionMapsEveryCase() {
    #expect(
      EditorFeature.editorErrorDescription(.notInstalled(id: "vscode", bundleID: "com.microsoft.VSCode"))
        == "vscode is not installed")
    #expect(
      EditorFeature.editorErrorDescription(.launchFailed(reason: "Gatekeeper blocked"))
        == "Could not launch editor: Gatekeeper blocked")
    #expect(
      EditorFeature.editorErrorDescription(.notADirectory(path: "/x"))
        == "Not a directory: /x")
  }

  @Test
  func resolveDefaultPrefersProjectOverride() {
    let resolved = EditorFeature.resolveDefault(
      projectOverride: "vscode",
      globalDefault: "zed",
      descriptors: [Self.sampleDescriptor]
    )
    #expect(resolved == .editor(Self.sampleDescriptor))
  }

  @Test
  func resolveDefaultFallsBackToFinderWhenNothingResolves() {
    let resolved = EditorFeature.resolveDefault(
      projectOverride: nil,
      globalDefault: nil,
      descriptors: [Self.sampleDescriptor]
    )
    #expect(resolved == .finder)
  }
}
