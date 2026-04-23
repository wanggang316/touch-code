import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer backing the "+ Create Worktree" sheet. State tracks user
/// input, three-way option loading (branch refs / local branches /
/// default remote branch), live branch-name validation, streaming
/// progress, and the post-create sidecar actions (append catalog,
/// select, open a Tab + Pane in the new directory).
///
/// Streaming progress buffer feeds from the `wt sw` driver. See
/// `docs/design-docs/worktree-management-design.md` §CreateWorktreeFeature.
@Reducer
struct CreateWorktreeFeature {
  @ObservableState
  struct State: Equatable {
    let projectID: ProjectID
    let spaceID: SpaceID
    /// Git root of the Project. Used to run all `wt` / `git` commands
    /// and to derive the Worktree's on-disk path together with
    /// `worktreesDirectory`.
    let repoRoot: URL
    /// Base directory (spec "Worktree path derivation"). The sheet
    /// itself is read-only on this — changing it lives in the Project
    /// options flow owned by T-PROJECT.
    let worktreesDirectory: URL

    // Options loaded asynchronously on presentation.
    var baseRefOptions: [String] = []
    var localBranchNamesLower: Set<String> = []
    var automaticBaseRef: String?
    var loadingOptions: Bool = true

    // User input.
    var branchNameDraft: String = ""
    var selectedBaseRef: String?
    var fetchOrigin: Bool = false
    var copyIgnored: Bool = false
    var copyUntracked: Bool = false

    // Transient derived state.
    var validationError: String?
    var submitError: String?
    var progressLines: [String] = []
    var isSubmitting: Bool = false
  }

  enum Action: Equatable {
    case onAppear
    case optionsLoaded(
      baseRefs: [String],
      localBranchNamesLower: Set<String>,
      automaticBaseRef: String?
    )
    case branchDraftChanged(String)
    case validated(String?)
    case baseRefSelected(String?)
    case fetchOriginToggled(Bool)
    case copyIgnoredToggled(Bool)
    case copyUntrackedToggled(Bool)

    case createButtonTapped
    case progressLine(String)
    case createFailed(String)
    case createSucceeded(URL)

    case cancelButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// Emitted after a successful create flow so the parent can
      /// dismiss the sheet. The new WorktreeID is not threaded back —
      /// the parent re-reads from `HierarchyManager.catalog`.
      case submitted
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(GitWorktreeClient.self) private var gitWorktreeClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        state.loadingOptions = true
        let repoRoot = state.repoRoot
        let client = gitWorktreeClient
        return .run { send in
          async let refs = (try? client.branchRefs(repoRoot)) ?? []
          async let locals =
            (try? client.localBranchNames(repoRoot)) ?? []
          async let auto = (try? client.defaultRemoteBranchRef(repoRoot)) ?? nil
          let loadedRefs = await refs
          let loadedLocals = await locals
          let loadedAuto = await auto
          await send(.optionsLoaded(
            baseRefs: loadedRefs,
            localBranchNamesLower: loadedLocals,
            automaticBaseRef: loadedAuto
          ))
        }

      case let .optionsLoaded(baseRefs, locals, auto):
        state.loadingOptions = false
        state.baseRefOptions = baseRefs
        state.localBranchNamesLower = locals
        state.automaticBaseRef = auto
        // Preserve a user-set value if they already picked one while
        // options were loading; otherwise seed with the automatic.
        if state.selectedBaseRef == nil {
          state.selectedBaseRef = auto ?? baseRefs.first
        }
        return .none

      case let .branchDraftChanged(draft):
        state.branchNameDraft = draft
        // Live-validate synchronously against the local-branch set we
        // already fetched. The `git check-ref-format` path is also
        // exercised on Create — no need to shell out on every keystroke.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          state.validationError = nil
        } else if trimmed.contains(where: \.isWhitespace) {
          state.validationError = "Branch names can't contain spaces."
        } else if state.localBranchNamesLower.contains(trimmed.lowercased()) {
          state.validationError = "Branch \"\(trimmed)\" already exists."
        } else {
          state.validationError = nil
        }
        return .none

      case let .validated(error):
        state.validationError = error
        return .none

      case let .baseRefSelected(ref):
        state.selectedBaseRef = ref
        return .none

      case let .fetchOriginToggled(value):
        state.fetchOrigin = value
        return .none

      case let .copyIgnoredToggled(value):
        state.copyIgnored = value
        return .none

      case let .copyUntrackedToggled(value):
        state.copyUntracked = value
        return .none

      case .createButtonTapped:
        let trimmed = state.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state.validationError == nil else {
          state.validationError = state.validationError ?? "Branch name required."
          return .none
        }
        guard let baseRef = state.selectedBaseRef, !baseRef.isEmpty else {
          state.validationError = "Pick a base ref."
          return .none
        }
        let directoryName = GitWorktreeClient.sanitizeBranchName(trimmed)
        guard !directoryName.isEmpty else {
          state.validationError = "Branch name produces an empty directory name."
          return .none
        }
        let targetURL = state.worktreesDirectory
          .appending(component: directoryName)
        if FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)) {
          state.submitError = """
            A folder named \"\(directoryName)\" already exists at the Project's \
            worktrees directory. Choose a different branch name.
            """
          return .none
        }

        state.isSubmitting = true
        state.submitError = nil
        state.progressLines = []

        let spec = CreateWorktreeSpec(
          repoRoot: state.repoRoot,
          baseDirectory: state.worktreesDirectory,
          name: directoryName,
          branch: trimmed,
          baseRef: baseRef,
          fetchOrigin: state.fetchOrigin,
          copyIgnored: state.copyIgnored,
          copyUntracked: state.copyUntracked
        )
        let client = gitWorktreeClient
        return .run { send in
          do {
            for try await event in client.createWorktreeStream(spec) {
              switch event {
              case .progressLine(let line):
                await send(.progressLine(line))
              case .finished(let path):
                await send(.createSucceeded(path))
                return
              }
            }
            await send(.createFailed("wt exited without reporting a path"))
          } catch let error as GitWorktreeError {
            await send(.createFailed(humanReadable(error)))
          } catch {
            await send(.createFailed(error.localizedDescription))
          }
        }

      case let .progressLine(line):
        state.progressLines.append(line)
        return .none

      case let .createFailed(message):
        state.isSubmitting = false
        state.submitError = message
        return .none

      case let .createSucceeded(path):
        state.isSubmitting = false
        let projectID = state.projectID
        let spaceID = state.spaceID
        let branch = state.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = GitWorktreeClient.sanitizeBranchName(branch)
        let pathString = path.standardizedFileURL.path(percentEncoded: false)
        do {
          let worktreeID = try hierarchyClient.createWorktreeWithGit(
            projectID, spaceID, branch, directoryName, pathString
          )
          try hierarchyClient.selectWorktree(worktreeID, projectID, spaceID)
          let tabID = try hierarchyClient.createTab(worktreeID, projectID, spaceID, nil)
          _ = try hierarchyClient.openPane(
            tabID, worktreeID, projectID, spaceID, pathString, nil
          )
        } catch {
          state.submitError = "Worktree created on disk, but failed to attach in the sidebar: \(error.localizedDescription)"
          return .none
        }
        return .send(.delegate(.submitted))

      case .cancelButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }

  /// Maps `GitWorktreeError` to sheet-banner text. Reads better than
  /// `localizedDescription`, which is often the raw stderr.
  private func humanReadable(_ error: GitWorktreeError) -> String {
    switch error {
    case .branchExists(let name):
      return "Branch \"\(name)\" already exists."
    case .invalidBranchName(let name):
      return "Branch name \"\(name)\" is not valid."
    case .refNotFound(let ref):
      return "Base ref not found: \(ref)"
    case .fetchFailed(let detail):
      return "git fetch origin failed: \(detail)"
    case .executableMissing:
      return "The bundled wt helper is missing. Reinstall touch-code."
    case .uncommittedChanges:
      return "The worktree has uncommitted changes."
    case .worktreeLocked(let detail):
      return "Worktree is locked: \(detail)"
    case .commandFailed(let command, let stderr):
      return "\(command): \(stderr)"
    }
  }
}
