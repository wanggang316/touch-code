import ComposableArchitecture
import Foundation
import TouchCodeCore

/// C8 editor-settings feature. Drives the Settings → Editors pane and the Worktree-header
/// dropdown. State is cached from `EditorClient.describe`; writes go through `SettingsStore`
/// (global default / custom editors) and `HierarchyClient.setDefaultEditor` (per-Project
/// override). The feature never holds a direct reference to `SettingsStore` — it dispatches
/// via the `editorClient` + `hierarchyClient` dependencies plus a dedicated
/// `SettingsWriter` injected at the edge (see `liveValue`).
@Reducer
struct EditorFeature {
  @ObservableState
  struct State: Equatable {
    /// Descriptors from the last successful `describe`. `nil` = never fetched.
    var descriptors: [EditorDescriptor] = []
    /// Latest global default read from `SettingsStore`. Kept in state so the picker has a
    /// local source of truth (views don't read the store directly — consistent with TCA).
    var globalDefault: EditorID?
    /// Latest custom editors. Views render the Settings list against this.
    var customEditors: [CustomEditor] = []
    /// Transient validation error for the "Add custom editor" form. Clears on next edit.
    var lastValidationError: EditorTemplateError?
    /// Monotonic counter that refreshes the descriptor cache on bump. Incremented by
    /// `.refreshRequested`.
    var refreshToken: Int = 0
  }

  enum Action: Equatable {
    /// Fired on view appear; re-fetches descriptors + pulls current settings.
    case onAppear
    case refreshRequested
    case descriptorsLoaded([EditorDescriptor])
    case settingsObserved(globalDefault: EditorID?, customEditors: [CustomEditor])
    case setGlobalDefault(EditorID?)
    case addCustomEditor(CustomEditor)
    case addCustomEditorFailed(EditorTemplateError)
    case removeCustomEditor(id: EditorID)
    case setProjectOverride(projectID: ProjectID, spaceID: SpaceID, editorID: EditorID?)
  }

  @Dependency(EditorClient.self) var editorClient
  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(SettingsWriter.self) var settingsWriter

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let reader = settingsWriter.readSnapshot
        return .merge(
          refresh(client: editorClient),
          .run { send in
            let snapshot = await reader()
            await send(.settingsObserved(
              globalDefault: snapshot.defaultEditorID,
              customEditors: snapshot.customEditors
            ))
          }
        )

      case .refreshRequested:
        state.refreshToken = state.refreshToken &+ 1
        return refresh(client: editorClient)

      case .descriptorsLoaded(let descriptors):
        state.descriptors = descriptors
        return .none

      case .settingsObserved(let globalDefault, let customEditors):
        state.globalDefault = globalDefault
        state.customEditors = customEditors
        return .none

      case .setGlobalDefault(let editorID):
        state.globalDefault = editorID
        let writer = settingsWriter.setDefaultEditorID
        return .run { _ in await writer(editorID) }

      case .addCustomEditor(let editor):
        state.lastValidationError = nil
        let writer = settingsWriter.addCustomEditor
        let reader = settingsWriter.readSnapshot
        return .run { send in
          let result = await writer(editor)
          switch result {
          case .success:
            let snapshot = await reader()
            await send(.settingsObserved(
              globalDefault: snapshot.defaultEditorID,
              customEditors: snapshot.customEditors
            ))
          case .failure(let err):
            await send(.addCustomEditorFailed(err))
          }
        }

      case .addCustomEditorFailed(let error):
        state.lastValidationError = error
        return .none

      case .removeCustomEditor(let id):
        state.customEditors.removeAll { $0.id == id }
        let writer = settingsWriter.removeCustomEditor
        return .run { _ in await writer(id) }

      case .setProjectOverride(let projectID, let spaceID, let editorID):
        let client = hierarchyClient
        return .run { _ in
          try? await MainActor.run {
            try client.setDefaultEditor(projectID, spaceID, editorID)
          }
        }
      }
    }
  }

  private func refresh(client: EditorClient) -> Effect<Action> {
    .run { send in
      let descriptors = await client.describe()
      await send(.descriptorsLoaded(descriptors))
    }
  }
}

// MARK: - SettingsWriter dependency

/// Narrow dependency over `SettingsStore` — the reducer sees async closures, not the
/// @Observable store itself. Keeps the reducer free of MainActor + Observation plumbing
/// and mocks cleanly for TestStore.
nonisolated struct SettingsWriter: Sendable {
  /// Reads a snapshot of the current settings. `@MainActor`-pumped.
  var readSnapshot: @Sendable () async -> Settings
  /// Writes the global default ID (nil clears).
  var setDefaultEditorID: @Sendable (EditorID?) async -> Void
  /// Upserts a custom editor. Returns `.success` on accept, `.failure` on validation error.
  var addCustomEditor: @Sendable (CustomEditor) async -> Result<Void, EditorTemplateError>
  /// Removes a custom editor by ID.
  var removeCustomEditor: @Sendable (EditorID) async -> Void
}

extension SettingsWriter {
  @MainActor
  static func live(_ store: SettingsStore) -> SettingsWriter {
    SettingsWriter(
      readSnapshot: { [weak store] in
        await MainActor.run { store?.settings ?? .default }
      },
      setDefaultEditorID: { [weak store] id in
        await MainActor.run { store?.setDefaultEditorID(id) }
      },
      addCustomEditor: { [weak store] editor in
        await MainActor.run {
          store?.addCustomEditor(editor) ?? .failure(.invalidID(editor.id))
        }
      },
      removeCustomEditor: { [weak store] id in
        await MainActor.run { _ = store?.removeCustomEditor(id: id) }
      }
    )
  }
}

extension SettingsWriter: DependencyKey {
  static let liveValue: SettingsWriter = SettingsWriter(
    readSnapshot: { fatalError("SettingsWriter.liveValue not configured; wire via `.withDependencies` at app startup") },
    setDefaultEditorID: { _ in fatalError("SettingsWriter.liveValue not configured") },
    addCustomEditor: { _ in fatalError("SettingsWriter.liveValue not configured") },
    removeCustomEditor: { _ in fatalError("SettingsWriter.liveValue not configured") }
  )

  static let testValue: SettingsWriter = SettingsWriter(
    readSnapshot: unimplemented("SettingsWriter.readSnapshot", placeholder: .default),
    setDefaultEditorID: unimplemented("SettingsWriter.setDefaultEditorID"),
    addCustomEditor: unimplemented("SettingsWriter.addCustomEditor", placeholder: .success(())),
    removeCustomEditor: unimplemented("SettingsWriter.removeCustomEditor")
  )
}

extension DependencyValues {
  var settingsWriter: SettingsWriter {
    get { self[SettingsWriter.self] }
    set { self[SettingsWriter.self] = newValue }
  }
}
