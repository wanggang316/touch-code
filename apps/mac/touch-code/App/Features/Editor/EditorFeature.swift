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

    /// Latest outcome of a WorktreeHeader "Open in …" click. Views observe to render
    /// success / failure toasts.
    var lastOpenResult: OpenResultMarker?

    /// Latest per-Project override outcome. Non-nil means "last write failed" (success
    /// clears automatically on next write attempt).
    var lastProjectOverrideFailure: String?
  }

  /// Test-friendly witness for editor-open outcomes. Carries enough info to render a
  /// toast without widening actions with non-Equatable payloads.
  enum OpenResultMarker: Equatable {
    case opened(editorID: EditorID, displayName: String)
    case failed(reason: String)
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
    case setProjectOverrideFailed(reason: String)
    /// Open request routed from the Worktree Header split button (and any other editor
    /// consumer). The action flows through the reducer so TestStore observes the effect;
    /// views do not hold a direct `@Dependency(EditorClient.self)`.
    case openRequested(editorID: EditorID, worktreePath: String, projectID: ProjectID?)
    case openSucceeded(editorID: EditorID, displayName: String)
    case openFailed(reason: String)
    /// T3 (⌘E shortcut): resolve the current Worktree's default editor via the
    /// per-Project override → global default → Finder fallback chain and forward to
    /// `.openRequested`. The caller (MainWindowCommands) supplies the already-resolved
    /// IDs + path so the reducer reads the catalog snapshot only for the override lookup.
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

      case .openRequested(let editorID, let worktreePath, let projectID):
        let client = editorClient
        let url = URL(fileURLWithPath: worktreePath)
        return .run { send in
          do {
            let choice = try await client.open(url, editorID, projectID)
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
        // T3 ⌘E: reuse T2's shared resolver. Look up the per-Project override
        // from the catalog snapshot, then delegate to `resolveDefault` which
        // already encodes the cascade-on-missing semantics. Map the returned
        // `ResolvedDefault` to an `EditorID` for `.openRequested`.
        let catalog = hierarchyClient.snapshot()
        let projectOverride = catalog
          .spaces.first(where: { $0.id == spaceID })?
          .projects.first(where: { $0.id == projectID })?
          .defaultEditor
        let resolvedID: EditorID
        switch Self.resolveDefault(
          projectOverride: projectOverride,
          globalDefault: state.globalDefault,
          descriptors: state.descriptors
        ) {
        case .editor(let descriptor): resolvedID = descriptor.id
        case .finder: resolvedID = Self.finderEditorID
        }
        return .send(.openRequested(
          editorID: resolvedID,
          worktreePath: worktreePath,
          projectID: projectID
        ))
      }
    }
  }

  /// Built-in Finder `EditorID`. Named alias of `EditorRegistry.finderID` so callers
  /// that need to dispatch the always-available fallback (T2 Header split button) do
  /// not re-hardcode the string `"finder"`.
  nonisolated static let finderEditorID: EditorID = EditorRegistry.finderID

  /// Result of resolving the Worktree's default editor for the Header's Open-in
  /// primary action. Resolution chain:
  ///   - per-Project override → descriptor, if present in `descriptors`
  ///   - global default       → descriptor, if present in `descriptors`
  ///   - otherwise             → `.finder`
  ///
  /// **Cascade-on-missing semantics.** If a configured override id is not in
  /// `descriptors` (e.g. the custom editor was removed), resolution does not
  /// fall through to `.finder` — it cascades to the global default, and only
  /// falls to Finder when neither override nor global resolves. This preserves
  /// the behavior users saw in the pre-T2 dropdown so a stale override id does
  /// not strand them on Finder when a global default is set. See
  /// `docs/exec-plans/0009-mw-t2-header.md` Decision Log D5.
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
       let match = descriptors.first(where: { $0.id == override }) {
      return .editor(match)
    }
    if let global = globalDefault,
       let match = descriptors.first(where: { $0.id == global }) {
      return .editor(match)
    }
    return .finder
  }

  /// Human-readable reason for an `EditorError`, surfaced as a toast subtitle by views.
  nonisolated static func editorErrorDescription(_ error: EditorError) -> String {
    switch error {
    case .notInstalled(let id, let binary):
      return "\(id) CLI (`\(binary)`) not found on PATH"
    case .spawnFailed(let reason): return "Could not launch editor: \(reason)"
    case .nonZeroExit(_, let stderr):
      return stderr.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "Editor exited with error"
    case .timedOut: return "Editor did not respond within 5 seconds"
    case .badTemplate(let id, let reason): return "Bad template for ‘\(id)’: \(reason)"
    case .notADirectory(let path): return "Not a directory: \(path)"
    case .unresolvedWorktree: return "No worktree resolved"
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
  var readSnapshot: @Sendable () async -> LegacyEditorSettings
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
