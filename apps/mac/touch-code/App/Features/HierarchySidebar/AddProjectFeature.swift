import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Drives the Add Project sheet. The parent (`HierarchySidebarFeature`) holds
/// this reducer's `State?` on its own state tree and scopes it via TCA's
/// `ifLet`; presentation is "state-is-non-nil". Responsibilities:
///
/// 1. Show an `NSOpenPanel` via `FolderPickerClient.pick`.
/// 2. Canonicalize the picked path (`HierarchyManager.canonical`) and check
///    for duplicate registration (`HierarchyClient.isPathRegistered`).
/// 3. Classify the folder as git-backed or non-git by calling
///    `GitWorktreeCLI.discoverGitRoot` (**add-time one-shot**; the reconciler
///    does not go through this path).
/// 4. Let the user edit the default name (last path component).
/// 5. On submit, call `HierarchyClient.addProject(...)` and delegate
///    `.projectAdded(ProjectID, SpaceID)` so the parent can kick the
///    reconciler.
/// 6. On duplicate + Reveal, delegate `.revealExisting(SpaceID, ProjectID)`.
@Reducer
struct AddProjectFeature {
  struct DuplicateRegistration: Equatable {
    var spaceID: SpaceID
    var projectID: ProjectID
  }

  @ObservableState
  struct State: Equatable {
    var targetSpaceID: SpaceID

    /// Canonical path after the picker. Nil until the user picks a folder.
    var pickedPath: String?
    /// `true` after classification if the folder is git-backed; `false` if not.
    /// Nil until `validationResolved` fires.
    var pickedIsGit: Bool?
    /// Resolved git root from `GitWorktreeCLI.discoverGitRoot`. Same as
    /// `pickedPath` for a repo root; different if the user picks a subdirectory
    /// of a repo. Nil for non-git Projects.
    var resolvedGitRoot: String?
    /// Non-nil → duplicate banner visible with a Reveal action.
    var duplicate: DuplicateRegistration?
    /// Name text-field draft. Seeded to the folder's last path component on
    /// `validationResolved`.
    var nameDraft: String = ""
    /// Inline inline-error message (non-fatal — user may retry). Clears on
    /// the next successful validation pass.
    var validationError: String?
    /// Debounces double-taps on Add while `addProject` is in flight.
    var isSubmitting: Bool = false

    /// The Add button is enabled only when the user has picked a valid,
    /// non-duplicate folder, classification finished, the name draft is
    /// non-blank, and a submission isn't already in flight.
    var canSubmit: Bool {
      pickedPath != nil
        && duplicate == nil
        && pickedIsGit != nil
        && !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isSubmitting
    }
  }

  enum Action: Equatable {
    case openPickerTapped
    case folderPicked(URL?)
    case validationStarted(canonicalPath: String)
    case validationResolved(gitRoot: String?)
    case nameDraftChanged(String)
    case submitTapped
    case submitCompleted(ProjectID)
    case revealExistingTapped
    case cancelTapped

    case delegate(Delegate)
    @CasePathable
    enum Delegate: Equatable {
      case projectAdded(ProjectID, SpaceID)
      case revealExisting(SpaceID, ProjectID)
      case dismiss
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(FolderPickerClient.self) private var folderPickerClient
  @Dependency(GitWorktreeCLI.self) private var gitCLI

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .openPickerTapped:
        return .run { send in
          let url = await folderPickerClient.pick("Add Project")
          await send(.folderPicked(url))
        }

      case .folderPicked(let url):
        guard let url else {
          return .send(.delegate(.dismiss))
        }
        let canonical = HierarchyManager.canonical(url.path)
        state.pickedPath = canonical
        state.pickedIsGit = nil
        state.resolvedGitRoot = nil
        state.validationError = nil

        if let existing = hierarchyClient.isPathRegistered(canonical) {
          state.duplicate = DuplicateRegistration(
            spaceID: existing.0,
            projectID: existing.1
          )
          // Seed a sensible name-draft placeholder anyway so the UI isn't blank
          // if the user clears the duplicate state and retries with a new path.
          state.nameDraft = (canonical as NSString).lastPathComponent
          return .none
        }
        state.duplicate = nil
        return .send(.validationStarted(canonicalPath: canonical))

      case .validationStarted(let path):
        return .run { send in
          let gitRoot = try? await gitCLI.discoverGitRoot(candidatePath: path)
          await send(.validationResolved(gitRoot: gitRoot))
        }

      case .validationResolved(let gitRoot):
        state.resolvedGitRoot = gitRoot
        state.pickedIsGit = gitRoot != nil
        if let pickedPath = state.pickedPath {
          state.nameDraft = (pickedPath as NSString).lastPathComponent
        }
        state.validationError = nil
        return .none

      case .nameDraftChanged(let text):
        state.nameDraft = text
        return .none

      case .submitTapped:
        guard state.canSubmit,
              let path = state.pickedPath
        else { return .none }
        let trimmed = state.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.isSubmitting = true
        let spaceID = state.targetSpaceID
        let gitRoot = state.resolvedGitRoot
        do {
          let projectID = try hierarchyClient.addProject(spaceID, trimmed, path, gitRoot)
          return .send(.submitCompleted(projectID))
        } catch {
          state.isSubmitting = false
          state.validationError = "Failed to add Project: \(error)"
          return .none
        }

      case .submitCompleted(let projectID):
        let spaceID = state.targetSpaceID
        return .run { send in
          await send(.delegate(.projectAdded(projectID, spaceID)))
          await send(.delegate(.dismiss))
        }

      case .revealExistingTapped:
        guard let duplicate = state.duplicate else { return .none }
        return .run { send in
          await send(.delegate(.revealExisting(duplicate.spaceID, duplicate.projectID)))
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
