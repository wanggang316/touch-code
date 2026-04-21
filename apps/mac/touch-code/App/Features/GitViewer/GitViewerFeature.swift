import ComposableArchitecture
import Foundation
import TouchCodeCore
import TouchCodeIPC

/// C7 read-only git viewer. Scoped to a single `WorktreeID`; resets on
/// `.worktreeSelected`. Drives `GitServiceClient` for log/diff/status and
/// delegates `.openInEditorRequested` to `EditorClient.open` (wired in
/// M6a over `LiveEditorService` from M5).
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
    /// `EditorClient.open` so per-Project editor overrides resolve. Updated
    /// alongside `worktreeID`.
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

    /// Monotonic nonce incremented when the reducer accepts `.copyLargeDiffCommandRequested`
    /// (user pressed ⌘⇧C while the placeholder is on screen). `LargeDiffPlaceholderView`
    /// observes the nonce via `.onChange` and writes to `NSPasteboard`. Separating the
    /// decision (reducer: should we copy?) from the I/O (view: perform the copy + show
    /// feedback) keeps the pasteboard call out of the reducer while still routing the
    /// keybinding through the same model every other binding uses.
    var copyLargeDiffCommandToken: Int = 0

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

    /// Result actions carry their originating `scope`. A scope switch between
    /// dispatch and completion races late results against the new state; the
    /// reducer drops any completion whose `scope` differs from `state.scope`
    /// instead of painting stale data. `.cancellable(cancelInFlight:)` cancels
    /// in-flight requests, but an effect that has *already* sent its result
    /// into the TCA mailbox will still deliver — this guard closes that gap.
    case logSucceeded(scope: DiffScope, page: LogPage)
    case logFailed(scope: DiffScope, error: GitError)
    case diffSucceeded(scope: DiffScope, diff: UnifiedDiff)
    case diffFailed(scope: DiffScope, error: GitError)

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
    /// User pressed ⌘⇧C while `.diffTooLarge` is on screen. Reducer guards that the
    /// placeholder is actually rendered and that a worktree path is cached before bumping
    /// `copyLargeDiffCommandToken`; the view observes the nonce and performs the paste.
    case copyLargeDiffCommandRequested
  }

  nonisolated enum CancelID: Sendable { case log, diff }

  @Dependency(GitServiceClient.self) var gitService
  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(EditorClient.self) var editorClient

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
        //
        // Note (0005 M4b.1 review): `hierarchyClient.snapshot()` is synchronous here — it
        // forwards the `@Observable HierarchyManager.catalog` property, which is always
        // main-actor-current. If the client's contract ever grows async (e.g. a future
        // storage-backed snapshot that loads from disk), this line becomes a latent blocking
        // call in a reducer. Migration path: fold the snapshot lookup into an effect that
        // sends `.worktreePathHintResolved(String?)` back to the reducer. Deferred until
        // the client signature actually changes to avoid reshaping reducers speculatively.
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

      case .logSucceeded(let originScope, let page):
        guard originScope == state.scope else { return .none }
        // Append-on-pagination if we're extending the current window; replace otherwise.
        if case .loaded(let existing) = state.logState,
          page.cursor.offset == existing.cursor.offset + existing.cursor.limit
        {
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

      case .logFailed(let originScope, let error):
        guard originScope == state.scope else { return .none }
        state.logState = .error(error)
        return .none

      case .diffSucceeded(let originScope, let diff):
        guard originScope == state.scope else { return .none }
        state.diffState = .loaded(diff)
        // Default-select the first file so `selectedFilePath` is never nil on a non-empty diff.
        if state.selectedFilePath == nil { state.selectedFilePath = diff.files.first?.id }
        return .none

      case .diffFailed(let originScope, let error):
        guard originScope == state.scope else { return .none }
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

      case .copyLargeDiffCommandRequested:
        // Guard: only fire when the large-diff placeholder is actually on screen AND we
        // have the path cached. Otherwise the keybinding is a no-op — matches the intent
        // expressed in the M4b.1 review "guarded by diffState == .error(.diffTooLarge)".
        guard case .error(.diffTooLarge) = state.diffState, state.worktreePathHint != nil else {
          return .none
        }
        state.copyLargeDiffCommandToken = state.copyLargeDiffCommandToken &+ 1
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
    let originScope = state.scope
    guard let path = worktreePath(for: state) else {
      return .send(.logFailed(scope: originScope, error: .invalidInput("no worktree path available")))
    }
    let cursor = state.cursor
    let client = self.gitService
    return .run { send in
      do {
        let page = try await client.log(path, cursor)
        await send(.logSucceeded(scope: originScope, page: page))
      } catch let error as GitError {
        await send(.logFailed(scope: originScope, error: error))
      } catch {
        await send(.logFailed(scope: originScope, error: .unparsable(context: String(describing: error))))
      }
    }
    .cancellable(id: CancelID.log, cancelInFlight: true)
  }

  private func diffRequest(state: State) -> Effect<Action> {
    let originScope = state.scope
    guard let path = worktreePath(for: state) else {
      return .send(.diffFailed(scope: originScope, error: .invalidInput("no worktree path available")))
    }
    let ignoreWhitespace = state.ignoreWhitespace
    let client = self.gitService
    return .run { send in
      do {
        let diff: UnifiedDiff
        switch originScope {
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
        await send(.diffSucceeded(scope: originScope, diff: diff))
      } catch let error as GitError {
        await send(.diffFailed(scope: originScope, error: error))
      } catch {
        await send(.diffFailed(scope: originScope, error: .unparsable(context: String(describing: error))))
      }
    }
    .cancellable(id: CancelID.diff, cancelInFlight: true)
  }

  private func editorOpenRequest(worktreeID: WorktreeID, projectID: ProjectID?) -> Effect<Action> {
    let client = self.editorClient
    let hierarchy = self.hierarchyClient
    return .run { send in
      let snapshot = await hierarchy.snapshot()
      guard let path = Self.worktreePath(in: snapshot, worktreeID: worktreeID) else {
        await send(.editorOpenFailed(reason: "Worktree path not found in catalog"))
        return
      }
      do {
        let choice = try await client.open(URL(fileURLWithPath: path), nil, projectID)
        await send(.editorOpened(editorID: choice.id))
      } catch let error as EditorError {
        await send(.editorOpenFailed(reason: Self.editorErrorDescription(error)))
      } catch {
        await send(.editorOpenFailed(reason: String(describing: error)))
      }
    }
  }

  /// Human-readable reason for an `EditorError`, surfaced as a toast subtitle by the view.
  nonisolated static func editorErrorDescription(_ error: EditorError) -> String {
    switch error {
    case .notInstalled(let id, let binary):
      return "\(id) CLI (`\(binary)`) not found on PATH"
    case .spawnFailed(let reason): return "Could not launch editor: \(reason)"
    case .nonZeroExit(_, let stderr):
      return stderr.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
        ?? "Editor exited with error"
    case .timedOut: return "Editor did not respond within 5 seconds"
    case .badTemplate(let id, let reason): return "Bad template for ‘\(id)’: \(reason)"
    case .notADirectory(let path): return "Not a directory: \(path)"
    case .unresolvedWorktree: return "No worktree resolved"
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
