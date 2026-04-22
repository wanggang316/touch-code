import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Project Options sheet. Launched from the `⋯` menu on a Project row.
/// Subsumes what used to be the standalone Rename Project sheet: name,
/// default editor, worktrees-directory override all live here. Save fans
/// out to the matching `HierarchyClient` setters in a fixed order; failure
/// keeps the sheet open with an inline error.
@Reducer
struct ProjectOptionsFeature {
  @ObservableState
  struct State: Equatable {
    var targetSpaceID: SpaceID
    var targetProjectID: ProjectID

    /// Snapshot of the Project's current persisted values at open-time so
    /// save-fan-out can skip setters whose drafts haven't changed. Captured
    /// when the parent opens the sheet.
    var originalName: String
    var originalDefaultEditor: EditorID?
    var originalWorktreesDirectory: String?

    var nameDraft: String
    var defaultEditorDraft: EditorID?
    /// Empty string means "use default (~/.touch-code/repos/<name>/)"; the
    /// reducer clears the override (nil) on save for that case.
    var worktreesDirectoryDraft: String

    /// Installed editor descriptors used to populate the "Editor" picker. Empty until the
    /// first `.onAppear` effect returns; the view renders a minimal menu in that window.
    var descriptors: [EditorDescriptor] = []

    var isSaving: Bool = false
    var validationError: String?

    /// Save is disabled when the name draft is blank after trimming.
    var canSave: Bool {
      !isSaving
        && !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  enum Action: Equatable {
    case onAppear
    case descriptorsLoaded([EditorDescriptor])
    case nameChanged(String)
    case editorChanged(EditorID?)
    case worktreesDirectoryChanged(String)
    case saveTapped
    case cancelTapped

    case delegate(Delegate)
    @CasePathable
    enum Delegate: Equatable {
      case dismiss
      case saved(ProjectID, SpaceID)
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(EditorClient.self) private var editorClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let client = editorClient
        return .run { send in
          await client.clearCache()
          let descriptors = await client.describe()
          await send(.descriptorsLoaded(descriptors))
        }

      case .descriptorsLoaded(let descriptors):
        state.descriptors = descriptors
        return .none

      case .nameChanged(let text):
        state.nameDraft = text
        return .none

      case .editorChanged(let editor):
        state.defaultEditorDraft = editor
        return .none

      case .worktreesDirectoryChanged(let text):
        state.worktreesDirectoryDraft = text
        return .none

      case .saveTapped:
        let trimmedName = state.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
          state.validationError = "Project name cannot be blank."
          return .none
        }
        state.isSaving = true
        state.validationError = nil
        let spaceID = state.targetSpaceID
        let projectID = state.targetProjectID
        let nameChanged = trimmedName != state.originalName
        let editorChanged = state.defaultEditorDraft != state.originalDefaultEditor
        let worktreesChanged = state.worktreesDirectoryDraft != (state.originalWorktreesDirectory ?? "")

        do {
          if nameChanged {
            try hierarchyClient.renameProject(projectID, spaceID, trimmedName)
          }
          if editorChanged {
            try hierarchyClient.setDefaultEditor(projectID, spaceID, state.defaultEditorDraft)
          }
          if worktreesChanged {
            try hierarchyClient.setProjectWorktreesDirectory(
              projectID, spaceID, state.worktreesDirectoryDraft
            )
          }
        } catch {
          state.isSaving = false
          state.validationError = "Failed to save: \(error)"
          return .none
        }
        return .run { send in
          await send(.delegate(.saved(projectID, spaceID)))
          await send(.delegate(.dismiss))
        }

      case .cancelTapped:
        return .send(.delegate(.dismiss))

      case .delegate:
        return .none
      }
    }
  }
}
