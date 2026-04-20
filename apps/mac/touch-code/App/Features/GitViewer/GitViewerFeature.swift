import ComposableArchitecture
import Foundation
import TouchCodeCore
import TouchCodeIPC

/// C7 read-only git viewer. Scoped to a single `WorktreeID`; resets on
/// `.worktreeSelected`. Drives `GitServiceClient` for log/diff/status and
/// delegates `.openInEditorRequested` to `EditorServiceFacade` (M3
/// placeholder, replaced by `EditorClient` in M6).
///
/// State modes are tracked via `logState` + `diffState`. Every scope
/// transition cancels the prior in-flight request via `CancelID` so a slow
/// repo cannot queue stale results.
@Reducer
struct GitViewerFeature {
  @ObservableState
  struct State: Equatable {
    /// Nil → "No Worktree selected" empty state. Set by `RootFeature` from
    /// `HierarchyClient.selectionChanges`.
    var worktreeID: WorktreeID?
    /// Project ID of the selected Worktree's parent. Required by
    /// `EditorServiceFacade.openDirectory` so per-project editor overrides
    /// resolve. Updated alongside `worktreeID`.
    var projectID: ProjectID?

    var scope: DiffScope = .working
    var logState: LogState = .idle
    var diffState: DiffState = .idle

    var focus: PaneFocus = .list
    var selectedFilePath: String?

    var cursor: LogPage.Cursor = .init(offset: 0, limit: 100)
    var ignoreWhitespace: Bool = false

    /// Latest editor-open outcome. Surfaced by the view as a toast in M4b.
    var lastEditorResult: EditorResultMarker?

    /// Client-side file-name filter applied to the files list. Empty string = no filter.
    /// Views substring-match case-insensitively against `FileChange.id`.
    var fileFilter: String = ""

    /// Monotonic nonce incremented whenever the reducer observes
    /// `.filterFocusRequested` (i.e. the user pressed `/`). The filter TextField's
    /// `@FocusState` observes this via `.onChange` to shift focus. The value itself is
    /// meaningless; only changes matter.
    var filterFocusToken: Int = 0

    /// Cached worktree path — populated alongside `worktreeID` so views can render the
    /// `cd '<abs-path>' && git …` Copy command from the large-diff placeholder without
    /// reaching back into `HierarchyClient.snapshot()`.
    var worktreePathHint: String?
  }

  enum LogState: Equatable {
    case idle
    case loading
    case loaded(LogPage)
    case error(GitError)
  }

  enum DiffState: Equatable {
    case idle
    case loading
    case loaded(UnifiedDiff)
    case error(GitError)
  }

  enum PaneFocus: String, Equatable, CaseIterable, Sendable {
    case list, files, hunks
  }

  enum Direction: Equatable { case up, down, home, end }

  /// Opaque marker for test assertions. Carries enough info to render the
  /// toast without widening `Action` to Equatable-hostile payloads.
  enum EditorResultMarker: Equatable {
    case opened(editorID: EditorID)
    case failed(reason: String)
  }

  enum Action: Equatable {
    /// Selection changed upstream. `projectID` + `worktreeID` required so
    /// the feature can resolve a Worktree.path snapshot and a Project.id.
    case worktreeSelected(projectID: ProjectID?, worktreeID: WorktreeID?)
    case scopeChanged(DiffScope)
    case refreshRequested
    case logScrolledToBottom

    case logSucceeded(LogPage)
    case logFailed(GitError)
    case diffSucceeded(UnifiedDiff)
    case diffFailed(GitError)

    case fileSelected(String?)
    case commitSelected(sha: String)
    case paneFocusCycled
    case keyboardNavigation(Direction)
    case whitespaceToggled

    case openInEditorRequested
    case editorOpened(editorID: EditorID)
    case editorOpenFailed(reason: String)

    /// User typed in the file-name filter TextField.
    case filterChanged(String)
    /// User pressed `/` — view observes the updated `filterFocusToken` and pulls focus.
    case filterFocusRequested
  }

  nonisolated enum CancelID: Sendable { case log, diff }

  @Dependency(GitServiceClient.self) var gitService
  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(EditorServiceFacade.self) var editorFacade

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .worktreeSelected(let projectID, let worktreeID):
        // New worktree → full reset. Same worktree → no-op.
        if state.worktreeID == worktreeID, state.projectID == projectID { return .none }
        state.worktreeID = worktreeID
        state.projectID = projectID
        state.scope = .working
        state.cursor = .init(offset: 0, limit: state.cursor.limit)
        state.logState = .idle
        state.diffState = .idle
        state.selectedFilePath = nil
        state.focus = .list
        state.fileFilter = ""
        // Cache the worktree path so the large-diff placeholder can render the Copy command
        // without a separate snapshot probe. Nil path clears the hint.
        if let worktreeID {
          state.worktreePathHint = Self.worktreePath(in: hierarchyClient.snapshot(), worktreeID: worktreeID)
        } else {
          state.worktreePathHint = nil
        }
        if worktreeID == nil {
          return .merge(.cancel(id: CancelID.log), .cancel(id: CancelID.diff))
        }
        return loadScope(state: &state)

      case .scopeChanged(let newScope):
        state.scope = newScope
        state.selectedFilePath = nil
        // Log pagination cursor resets when entering .log anew.
        if case .log = newScope {
          state.cursor = .init(offset: 0, limit: state.cursor.limit)
          state.logState = .loading
          state.diffState = .idle
          return logRequest(state: state)
        }
        state.logState = .idle
        state.diffState = .loading
        return diffRequest(state: state)

      case .refreshRequested:
        return loadScope(state: &state)

      case .logScrolledToBottom:
        guard case .loaded(let page) = state.logState, page.hasMore else { return .none }
        state.cursor = .init(offset: page.cursor.offset + page.cursor.limit, limit: page.cursor.limit)
        return logRequest(state: state)

      case .logSucceeded(let page):
        // Append-on-pagination if we're extending the current window; replace otherwise.
        if case .loaded(let existing) = state.logState,
           page.cursor.offset == existing.cursor.offset + existing.cursor.limit {
          let merged = LogPage(
            cursor: LogPage.Cursor(
              offset: existing.cursor.offset,
              limit: existing.cursor.limit + page.cursor.limit
            ),
            commits: existing.commits + page.commits,
            hasMore: page.hasMore
          )
          state.logState = .loaded(merged)
        } else {
          state.logState = .loaded(page)
        }
        return .none

      case .logFailed(let error):
        state.logState = .error(error)
        return .none

      case .diffSucceeded(let diff):
        state.diffState = .loaded(diff)
        // Default-select the first file so `selectedFilePath` is never nil on a non-empty diff.
        if state.selectedFilePath == nil { state.selectedFilePath = diff.files.first?.id }
        return .none

      case .diffFailed(let error):
        state.diffState = .error(error)
        return .none

      case .fileSelected(let path):
        state.selectedFilePath = path
        return .none

      case .commitSelected(let sha):
        // Pre-validate — avoids the service-layer round-trip on clearly bad input.
        guard GitShaValidator.isValid(sha) else { return .none }
        state.scope = .commit(sha: sha)
        state.diffState = .loading
        state.selectedFilePath = nil
        return diffRequest(state: state)

      case .paneFocusCycled:
        let order: [PaneFocus] = [.list, .files, .hunks]
        let nextIdx = ((order.firstIndex(of: state.focus) ?? 0) + 1) % order.count
        state.focus = order[nextIdx]
        return .none

      case .keyboardNavigation:
        // List-selection movement is a view-layer concern; reducer only tracks focus.
        return .none

      case .whitespaceToggled:
        state.ignoreWhitespace.toggle()
        // Re-issue if currently showing a diff; log scope is unaffected.
        switch state.scope {
        case .working, .staged, .commit:
          state.diffState = .loading
          return diffRequest(state: state)
        case .log:
          return .none
        }

      case .openInEditorRequested:
        guard let worktreeID = state.worktreeID else { return .none }
        let projectID = state.projectID
        return editorOpenRequest(worktreeID: worktreeID, projectID: projectID)

      case .editorOpened(let id):
        state.lastEditorResult = .opened(editorID: id)
        return .none

      case .editorOpenFailed(let reason):
        state.lastEditorResult = .failed(reason: reason)
        return .none

      case .filterChanged(let s):
        state.fileFilter = s
        return .none

      case .filterFocusRequested:
        // Monotonic nonce; view observes the change and shifts focus to the TextField.
        // Overflow is impossible in practice (would need 2^63 key presses in one session).
        state.filterFocusToken = state.filterFocusToken &+ 1
        return .none
      }
    }
  }

  // MARK: - Effect builders

  private func loadScope(state: inout State) -> Effect<Action> {
    guard state.worktreeID != nil else { return .none }
    if case .log = state.scope {
      state.logState = .loading
      state.diffState = .idle
      return logRequest(state: state)
    }
    state.logState = .idle
    state.diffState = .loading
    return diffRequest(state: state)
  }

  private func logRequest(state: State) -> Effect<Action> {
    guard let path = worktreePath(for: state) else {
      return .send(.logFailed(.invalidInput("no worktree path available")))
    }
    let cursor = state.cursor
    let client = self.gitService
    return .run { send in
      do {
        let page = try await client.log(path, cursor)
        await send(.logSucceeded(page))
      } catch let error as GitError {
        await send(.logFailed(error))
      } catch {
        await send(.logFailed(.unparsable(context: String(describing: error))))
      }
    }
    .cancellable(id: CancelID.log, cancelInFlight: true)
  }

  private func diffRequest(state: State) -> Effect<Action> {
    guard let path = worktreePath(for: state) else {
      return .send(.diffFailed(.invalidInput("no worktree path available")))
    }
    let scope = state.scope
    let ignoreWhitespace = state.ignoreWhitespace
    let client = self.gitService
    return .run { send in
      do {
        let diff: UnifiedDiff
        switch scope {
        case .working:
          diff = try await client.workingTreeDiff(path, ignoreWhitespace)
        case .staged:
          diff = try await client.stagedDiff(path, ignoreWhitespace)
        case .commit(let sha):
          diff = try await client.commitDiff(path, sha, ignoreWhitespace)
        case .log:
          // Log scope goes through logRequest — defensive branch.
          return
        }
        await send(.diffSucceeded(diff))
      } catch let error as GitError {
        await send(.diffFailed(error))
      } catch {
        await send(.diffFailed(.unparsable(context: String(describing: error))))
      }
    }
    .cancellable(id: CancelID.diff, cancelInFlight: true)
  }

  private func editorOpenRequest(worktreeID: WorktreeID, projectID: ProjectID?) -> Effect<Action> {
    let client = self.editorFacade
    let hierarchy = self.hierarchyClient
    return .run { send in
      let snapshot = await hierarchy.snapshot()
      guard let path = Self.worktreePath(in: snapshot, worktreeID: worktreeID) else {
        await send(.editorOpenFailed(reason: "Worktree path not found in catalog"))
        return
      }
      do {
        let choice = try await client.openDirectory(
          URL(fileURLWithPath: path), nil, projectID
        )
        await send(.editorOpened(editorID: choice.id))
      } catch EditorPlaceholderError.notYetImplemented {
        await send(.editorOpenFailed(reason: "Editor service not yet available (M3 placeholder)"))
      } catch {
        await send(.editorOpenFailed(reason: String(describing: error)))
      }
    }
  }

  // MARK: - Snapshot path resolution

  /// Resolves the Worktree.path from the hierarchy snapshot. Uses the
  /// `HierarchyClient` dependency which already proxies the `@Observable`
  /// catalog. The `state.projectID` disambiguates worktrees with duplicate
  /// IDs across Projects (shouldn't happen per design, but the linear scan
  /// below still disambiguates cleanly).
  private func worktreePath(for state: State) -> URL? {
    guard let worktreeID = state.worktreeID else { return nil }
    let snapshot = hierarchyClient.snapshot()
    guard let path = Self.worktreePath(in: snapshot, worktreeID: worktreeID) else { return nil }
    return URL(fileURLWithPath: path)
  }

  fileprivate nonisolated static func worktreePath(in catalog: Catalog, worktreeID: WorktreeID) -> String? {
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees where worktree.id == worktreeID {
          return worktree.path
        }
      }
    }
    return nil
  }
}
