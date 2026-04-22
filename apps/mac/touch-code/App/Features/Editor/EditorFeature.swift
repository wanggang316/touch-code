import ComposableArchitecture
import Foundation
import TouchCodeCore

/// C8a editor feature. Drives the Worktree-header dropdown and the Settings default-editor
/// picker. State is a cached `describe()` result + the currently stored global default.
/// Custom-editor plumbing (add / update / remove) is gone — C8a retired `customEditors`.
///
/// Per-Project override handling lives here (not in the service): the `.openDefault…`
/// action reads `Project.defaultEditor` out of the hierarchy snapshot and folds it into the
/// `preferred` hand-off. The service itself sees only an `EditorID?`.
@Reducer
struct EditorFeature {
  @ObservableState
  struct State: Equatable {
    /// Descriptors from the last successful `describe`. Empty until first fetch.
    var descriptors: [EditorDescriptor] = []
    /// Latest global default read from `SettingsStore`. Views bind the dropdown selection
    /// to this; setters dispatch `.setGlobalDefault`.
    var globalDefault: EditorID?
    /// Monotonic counter that forces a `describe()` re-fetch on bump. Incremented by
    /// `.refreshRequested`.
    var refreshToken: Int = 0

    /// Latest outcome of a `.openRequested` effect. Views observe to render toasts.
    var lastOpenResult: OpenResultMarker?

    /// Latest per-Project override write outcome. Non-nil means "last write failed".
    var lastProjectOverrideFailure: String?
  }

  /// Test-friendly witness for editor-open outcomes.
  enum OpenResultMarker: Equatable {
    case opened(editorID: EditorID, displayName: String)
    case failed(reason: String)
  }

  enum Action: Equatable {
    /// Fired on view appear; re-fetches descriptors and reads current settings.
    case onAppear
    case refreshRequested
    case descriptorsLoaded([EditorDescriptor])
    case settingsObserved(globalDefault: EditorID?)
    case setGlobalDefault(EditorID?)
    case setProjectOverride(projectID: ProjectID, spaceID: SpaceID, editorID: EditorID?)
    case setProjectOverrideFailed(reason: String)
    case openRequested(editorID: EditorID?, worktreePath: String, projectID: ProjectID?)
    case openSucceeded(editorID: EditorID, displayName: String)
    case openFailed(reason: String)
    /// T3 (⌘E): resolve the Worktree's default editor via per-Project override → global
    /// default → priority walk, then forward to `.openRequested` with a concrete preferred.
    case openDefaultInCurrentWorktreeRequested(
      spaceID: SpaceID,
      projectID: ProjectID,
      worktreeID: WorktreeID,
      worktreePath: String
    )
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
            await send(.settingsObserved(globalDefault: snapshot.general.defaultEditorID))
          }
        )

      case .refreshRequested:
        state.refreshToken = state.refreshToken &+ 1
        let client = editorClient
        return .run { send in
          await client.clearCache()
          let descriptors = await client.describe()
          await send(.descriptorsLoaded(descriptors))
        }

      case .descriptorsLoaded(let descriptors):
        state.descriptors = descriptors
        return .none

      case .settingsObserved(let globalDefault):
        state.globalDefault = globalDefault
        return .none

      case .setGlobalDefault(let editorID):
        state.globalDefault = editorID
        let writer = settingsWriter.setDefaultEditorID
        return .run { _ in await writer(editorID) }

      case .setProjectOverride(let projectID, let spaceID, let editorID):
        let client = hierarchyClient
        state.lastProjectOverrideFailure = nil
        return .run { send in
          do {
            try await MainActor.run {
              try client.setDefaultEditor(projectID, spaceID, editorID)
            }
          } catch {
            await send(.setProjectOverrideFailed(reason: String(describing: error)))
          }
        }

      case .setProjectOverrideFailed(let reason):
        state.lastProjectOverrideFailure = reason
        return .none

      case .openRequested(let editorID, let worktreePath, _):
        let client = editorClient
        let url = URL(fileURLWithPath: worktreePath)
        return .run { send in
          do {
            let choice = try await client.open(url, editorID)
            await send(.openSucceeded(editorID: choice.id, displayName: choice.displayName))
          } catch let error as EditorError {
            await send(.openFailed(reason: Self.editorErrorDescription(error)))
          } catch {
            await send(.openFailed(reason: String(describing: error)))
          }
        }

      case .openSucceeded(let id, let name):
        state.lastOpenResult = .opened(editorID: id, displayName: name)
        return .none

      case .openFailed(let reason):
        state.lastOpenResult = .failed(reason: reason)
        return .none

      case .openDefaultInCurrentWorktreeRequested(let spaceID, let projectID, _, let worktreePath):
        // Look up per-Project override in the catalog snapshot, then fold it into the
        // service's `preferred` argument. `resolveDefault` encodes the cascade so an
        // override that's not present in `state.descriptors` silently falls through.
        let catalog = hierarchyClient.snapshot()
        let projectOverride = catalog
          .spaces.first(where: { $0.id == spaceID })?
          .projects.first(where: { $0.id == projectID })?
          .defaultEditor
        let preferred: EditorID?
        switch Self.resolveDefault(
          projectOverride: projectOverride,
          globalDefault: state.globalDefault,
          descriptors: state.descriptors
        ) {
        case .editor(let descriptor): preferred = descriptor.id
        case .finder: preferred = Self.finderEditorID
        }
        return .send(
          .openRequested(
            editorID: preferred,
            worktreePath: worktreePath,
            projectID: projectID
          ))
      }
    }
  }

  /// Built-in Finder `EditorID`. Aliased from `EditorRegistry.finderID` so callers that
  /// need the always-installed fallback don't hand-roll the string literal.
  nonisolated static let finderEditorID: EditorID = EditorRegistry.finderID

  /// Result of resolving the Worktree's default editor for the Header "Open" primary
  /// action. Cascade-on-missing: an override id that's absent from `descriptors` does not
  /// strand the user on Finder when a global default is installed.
  nonisolated enum ResolvedDefault: Equatable {
    case editor(EditorDescriptor)
    case finder
  }

  nonisolated static func resolveDefault(
    projectOverride: EditorID?,
    globalDefault: EditorID?,
    descriptors: [EditorDescriptor]
  ) -> ResolvedDefault {
    if let override = projectOverride,
      let match = descriptors.first(where: { $0.id == override })
    {
      return .editor(match)
    }
    if let global = globalDefault,
      let match = descriptors.first(where: { $0.id == global })
    {
      return .editor(match)
    }
    return .finder
  }

  /// Human-readable reason for an `EditorError`, surfaced as a toast subtitle by views.
  nonisolated static func editorErrorDescription(_ error: EditorError) -> String {
    switch error {
    case .notInstalled(let id, _):
      return "\(id) is not installed"
    case .launchFailed(let reason):
      return "Could not launch editor: \(reason)"
    case .notADirectory(let path):
      return "Not a directory: \(path)"
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

/// Narrow dependency over `SettingsStore`. C8a removes the custom-editor surface; only the
/// snapshot read + default-ID writer remain.
nonisolated struct SettingsWriter: Sendable {
  var readSnapshot: @Sendable () async -> Settings
  var setDefaultEditorID: @Sendable (EditorID?) async -> Void
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
      }
    )
  }
}

extension SettingsWriter: DependencyKey {
  static let liveValue: SettingsWriter = SettingsWriter(
    readSnapshot: {
      fatalError("SettingsWriter.liveValue not configured; wire via `.withDependencies` at app startup")
    },
    setDefaultEditorID: { _ in fatalError("SettingsWriter.liveValue not configured") }
  )

  static let testValue: SettingsWriter = SettingsWriter(
    readSnapshot: unimplemented("SettingsWriter.readSnapshot", placeholder: .default),
    setDefaultEditorID: unimplemented("SettingsWriter.setDefaultEditorID")
  )
}

extension DependencyValues {
  var settingsWriter: SettingsWriter {
    get { self[SettingsWriter.self] }
    set { self[SettingsWriter.self] = newValue }
  }
}
