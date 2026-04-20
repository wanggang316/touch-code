import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore
import TouchCodeIPC
@testable import touch_code

@MainActor
struct GitViewerFeatureTests {
  // MARK: - Fixtures

  nonisolated static let sampleWorktreeID = WorktreeID()
  nonisolated static let sampleProjectID = ProjectID()
  nonisolated static let sampleSpaceID = SpaceID()
  nonisolated static let samplePath = "/tmp/touch-code-test-repo"

  nonisolated static func catalogWithWorktree() -> Catalog {
    let panel = Panel(workingDirectory: samplePath)
    let tab = Tab(splitTree: SplitTree(leaf: panel.id), panels: [panel])
    let worktree = Worktree(
      id: sampleWorktreeID,
      name: "main",
      path: samplePath,
      branch: "main",
      tabs: [tab],
      selectedTabID: tab.id
    )
    let project = Project(
      id: sampleProjectID,
      name: "repo",
      rootPath: samplePath,
      gitRoot: samplePath,
      worktrees: [worktree],
      selectedWorktreeID: worktree.id
    )
    let space = Space(id: sampleSpaceID, name: "work", projects: [project], selectedProjectID: project.id)
    return Catalog(spaces: [space], selectedSpaceID: space.id)
  }

  nonisolated static func sampleDiff(scope: DiffScope = .working) -> UnifiedDiff {
    let file = FileChange(
      id: "README.md", kind: .modified, isBinary: false,
      linesAdded: 1, linesRemoved: 1,
      hunks: [
        DiffHunk(
          header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
          lines: [
            DiffLine(kind: .removed, text: "old"),
            DiffLine(kind: .added, text: "new"),
          ]
        )
      ]
    )
    return UnifiedDiff(scope: scope, files: [file])
  }

  nonisolated static func sampleLogPage(offset: Int = 0, limit: Int = 100, hasMore: Bool = false, count: Int = 3) -> LogPage {
    let commits = (0..<count).map { idx in
      Commit(
        id: String(format: "%040d", idx),
        authorName: "Gump",
        authorEmail: "gump@example.com",
        date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + idx)),
        subject: "commit #\(idx)",
        parents: idx == 0 ? [] : [String(format: "%040d", idx - 1)]
      )
    }
    return LogPage(
      cursor: .init(offset: offset, limit: limit),
      commits: commits,
      hasMore: hasMore
    )
  }

  // MARK: - Worktree selection

  @Test
  func worktreeSelectedNilFromPopulatedStateResets() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .commit(sha: "deadbee")
    initial.diffState = .loaded(Self.sampleDiff(scope: .commit(sha: "deadbee")))
    initial.selectedFilePath = "README.md"
    initial.focus = .hunks

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.worktreeSelected(projectID: nil, worktreeID: nil)) { state in
      state.worktreeID = nil
      state.projectID = nil
      state.scope = .working
      state.cursor = .init(offset: 0, limit: 100)
      state.logState = .idle
      state.diffState = .idle
      state.selectedFilePath = nil
      state.focus = .list
    }
  }

  @Test
  func worktreeSelectedKicksOffWorkingTreeDiff() async {
    let store = TestStore(initialState: GitViewerFeature.State()) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.workingTreeDiff = { _, _ in Self.sampleDiff() }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.worktreeSelected(projectID: Self.sampleProjectID, worktreeID: Self.sampleWorktreeID)) {
      $0.projectID = Self.sampleProjectID
      $0.worktreeID = Self.sampleWorktreeID
      $0.worktreePathHint = Self.samplePath
      $0.diffState = .loading
    }
    await store.receive(\.diffSucceeded) {
      $0.diffState = .loaded(Self.sampleDiff())
      $0.selectedFilePath = "README.md"
    }
  }

  @Test
  func reSelectingSameWorktreeIsNoop() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    // No effect scheduled; TestStore would assert on any surprise action.
    await store.send(.worktreeSelected(projectID: Self.sampleProjectID, worktreeID: Self.sampleWorktreeID))
  }

  // MARK: - Scope transitions

  @Test
  func scopeChangeToLogIssuesLogRequest() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.diffState = .loaded(Self.sampleDiff())

    let logPage = Self.sampleLogPage()
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.log = { _, _ in logPage }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.scopeChanged(.log)) {
      $0.scope = .log
      $0.selectedFilePath = nil
      $0.logState = .loading
      $0.diffState = .idle
    }
    await store.receive(\.logSucceeded) { $0.logState = .loaded(logPage) }
  }

  @Test
  func scopeChangeToStagedIssuesStagedDiff() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID

    let stagedDiff = Self.sampleDiff(scope: .staged)
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.stagedDiff = { _, _ in stagedDiff }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.scopeChanged(.staged)) {
      $0.scope = .staged
      $0.selectedFilePath = nil
      $0.diffState = .loading
    }
    await store.receive(\.diffSucceeded) {
      $0.diffState = .loaded(stagedDiff)
      $0.selectedFilePath = "README.md"
    }
  }

  // MARK: - Commit selection

  @Test
  func commitSelectedWithValidShaMovesIntoCommitScope() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .log
    initial.logState = .loaded(Self.sampleLogPage())

    let commitDiff = Self.sampleDiff(scope: .commit(sha: "abc1234"))
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.commitDiff = { _, _, _ in commitDiff }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.commitSelected(sha: "abc1234")) {
      $0.scope = .commit(sha: "abc1234")
      $0.diffState = .loading
      $0.selectedFilePath = nil
    }
    await store.receive(\.diffSucceeded) {
      $0.diffState = .loaded(commitDiff)
      $0.selectedFilePath = "README.md"
    }
  }

  @Test
  func commitSelectedWithInvalidShaIsNoop() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .log

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }
    // Invalid SHA is rejected before any service call. TestStore would fail
    // if the unimplemented `commitDiff` stub were invoked.
    await store.send(.commitSelected(sha: "notahex"))
  }

  // MARK: - Pagination

  @Test
  func logScrolledToBottomAppendsNextPage() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .log
    let firstPage = Self.sampleLogPage(offset: 0, limit: 100, hasMore: true, count: 100)
    initial.logState = .loaded(firstPage)
    initial.cursor = .init(offset: 0, limit: 100)

    let secondPage = Self.sampleLogPage(offset: 100, limit: 100, hasMore: false, count: 50)
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.log = { _, _ in secondPage }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.logScrolledToBottom) {
      $0.cursor = .init(offset: 100, limit: 100)
    }
    let expectedMerged = LogPage(
      cursor: LogPage.Cursor(offset: 0, limit: 200),
      commits: firstPage.commits + secondPage.commits,
      hasMore: false
    )
    await store.receive(\.logSucceeded) { state in
      state.logState = .loaded(expectedMerged)
    }
  }

  @Test
  func logScrolledToBottomWithoutMoreIsNoop() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.scope = .log
    initial.logState = .loaded(Self.sampleLogPage(hasMore: false))

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.logScrolledToBottom)
  }

  // MARK: - Errors

  @Test
  func diffFailedSurfacesError() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.workingTreeDiff = { _, _ in throw GitError.exec(code: 1, stderr: "fatal") }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.scopeChanged(.working)) {
      $0.scope = .working
      $0.selectedFilePath = nil
      $0.diffState = .loading
    }
    await store.receive(\.diffFailed) {
      $0.diffState = .error(.exec(code: 1, stderr: "fatal"))
    }
  }

  // MARK: - Focus + whitespace

  @Test
  func paneFocusCyclesThroughListFilesHunks() async {
    let store = TestStore(initialState: GitViewerFeature.State()) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.paneFocusCycled) { $0.focus = .files }
    await store.send(.paneFocusCycled) { $0.focus = .hunks }
    await store.send(.paneFocusCycled) { $0.focus = .list }
  }

  @Test
  func whitespaceToggleReissuesDiffWithFlagPassedThrough() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .working
    initial.diffState = .loaded(Self.sampleDiff())

    let observedIgnoreWhitespace = LockIsolated<Bool?>(nil)
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.workingTreeDiff = { _, ignoreWhitespace in
        observedIgnoreWhitespace.setValue(ignoreWhitespace)
        return Self.sampleDiff()
      }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.whitespaceToggled) {
      $0.ignoreWhitespace = true
      $0.diffState = .loading
    }
    await store.receive(\.diffSucceeded) { state in
      state.diffState = .loaded(Self.sampleDiff())
      state.selectedFilePath = "README.md"
    }
    #expect(observedIgnoreWhitespace.value == true,
            "whitespace flag must reach the service on re-issue, not be silently dropped")
  }

  @Test
  func scopeChangeCancelsInFlightDiff() async {
    // Prove the `.cancellable(id: CancelID.diff, cancelInFlight: true)` invariant: a rapid
    // scope switch cancels the first request so its response never arrives.
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID

    let stagedDiff = Self.sampleDiff(scope: .staged)
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      // First request hangs until its Task is cancelled — which is exactly what
      // `cancelInFlight: true` does when a second .diff request is scheduled.
      $0.gitService.workingTreeDiff = { _, _ in
        try await Task.sleep(for: .seconds(30))
        return Self.sampleDiff(scope: .working) // unreachable
      }
      $0.gitService.stagedDiff = { _, _ in stagedDiff }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }

    await store.send(.scopeChanged(.working)) {
      $0.scope = .working
      $0.selectedFilePath = nil
      $0.diffState = .loading
    }
    // Switch scope while the first request is still pending. The first effect is cancelled
    // in-flight; TestStore sees no .diffSucceeded for the working scope.
    await store.send(.scopeChanged(.staged)) {
      $0.scope = .staged
      $0.diffState = .loading
    }
    // Only the staged response arrives.
    await store.receive(\.diffSucceeded) { state in
      state.diffState = .loaded(stagedDiff)
      state.selectedFilePath = "README.md"
    }
    // TestStore enforces no-stray-actions at teardown — if the cancelled effect somehow
    // sent .diffSucceeded(working) it would fail the test.
  }

  @Test
  func whitespaceToggleInLogScopeDoesNotReissue() async {
    var initial = GitViewerFeature.State()
    initial.scope = .log
    initial.worktreeID = Self.sampleWorktreeID

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.whitespaceToggled) { $0.ignoreWhitespace = true }
  }

  // MARK: - Editor facade delegation

  @Test
  func openInEditorRequestedSurfacesNotInstalledAsFailure() async {
    // Replaces the M3 `openInEditorRequestedSurfacesPlaceholderFailure`. The facade's
    // placeholder-error is gone in M6a; the analog is `EditorError.notInstalled` when the
    // preferred editor's binary is missing on PATH.
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient.open = { _, _, _ in
        throw EditorError.notInstalled(id: "zed", binary: "zed")
      }
    }
    await store.send(.openInEditorRequested)
    await store.receive(\.editorOpenFailed) { state in
      state.lastEditorResult = .failed(reason: "zed CLI (`zed`) not found on PATH")
    }
  }

  @Test
  func openInEditorRequestedWithInstalledFakeSurfacesSuccess() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID

    let cursor = EditorChoice(
      id: "cursor",
      displayName: "Cursor",
      binaryPath: URL(fileURLWithPath: "/usr/local/bin/cursor"),
      argv: ["/usr/local/bin/cursor", Self.samplePath]
    )
    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient.open = { _, _, _ in cursor }
    }
    await store.send(.openInEditorRequested)
    await store.receive(\.editorOpened) {
      $0.lastEditorResult = .opened(editorID: "cursor")
    }
  }

  @Test
  func openInEditorWithUnknownWorktreeSurfacesFailure() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = WorktreeID() // not in catalog
    initial.projectID = ProjectID()

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient.snapshot = { Catalog(spaces: [], selectedSpaceID: nil) }
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.openInEditorRequested)
    await store.receive(\.editorOpenFailed) { state in
      state.lastEditorResult = .failed(reason: "Worktree path not found in catalog")
    }
  }

  // MARK: - Refresh

  @Test
  func refreshReIssuesCurrentScope() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .working
    initial.diffState = .loaded(Self.sampleDiff())

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService.workingTreeDiff = { _, _ in Self.sampleDiff() }
      $0.hierarchyClient.snapshot = { Self.catalogWithWorktree() }
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.refreshRequested) { $0.diffState = .loading }
    await store.receive(\.diffSucceeded) { state in
      state.diffState = .loaded(Self.sampleDiff())
      state.selectedFilePath = "README.md"
    }
  }

  // MARK: - Stale-scope result race

  @Test
  func diffSucceededWithStaleScopeIsDroppedNotPainted() async {
    // Simulates a late .diffSucceeded that was dispatched for `.working` but arrives
    // after the user already switched to `.staged`. The guard added alongside the new
    // `scope:` payload on result actions drops the stale delivery so the current
    // `.staged` loading state is not overwritten with working-tree data.
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .staged
    initial.diffState = .loading

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    // No state change: the reducer guards on originScope != state.scope.
    await store.send(.diffSucceeded(scope: .working, diff: Self.sampleDiff(scope: .working)))
    await store.send(.logSucceeded(scope: .log, page: Self.sampleLogPage()))
    await store.send(.diffFailed(scope: .working, error: .notARepo))
    await store.send(.logFailed(scope: .log, error: .notARepo))
  }

  @Test
  func diffSucceededWithMatchingScopeIsApplied() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .working
    initial.diffState = .loading

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    let diff = Self.sampleDiff(scope: .working)
    await store.send(.diffSucceeded(scope: .working, diff: diff)) {
      $0.diffState = .loaded(diff)
      $0.selectedFilePath = "README.md"
    }
  }

  // MARK: - File selection

  // MARK: - Copy large-diff command

  @Test
  func copyCommandBumpsTokenWhenDiffTooLargeAndPathCached() async {
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .working
    initial.diffState = .error(.diffTooLarge)
    initial.worktreePathHint = Self.samplePath

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    #expect(store.state.copyLargeDiffCommandToken == 0)
    await store.send(.copyLargeDiffCommandRequested) {
      $0.copyLargeDiffCommandToken = 1
    }
    await store.send(.copyLargeDiffCommandRequested) {
      $0.copyLargeDiffCommandToken = 2
    }
  }

  @Test
  func copyCommandIsNoopOutsideDiffTooLargeError() async {
    // Guard (a): placeholder is not on screen.
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .working
    initial.diffState = .loaded(Self.sampleDiff())
    initial.worktreePathHint = Self.samplePath

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.copyLargeDiffCommandRequested) // no mutation
  }

  @Test
  func copyCommandIsNoopWhenWorktreePathNotCached() async {
    // Guard (b): placeholder IS on screen but worktreePathHint is nil. Fires e.g. when the
    // user navigated through a path-less intermediate state. The token must stay pinned.
    var initial = GitViewerFeature.State()
    initial.worktreeID = Self.sampleWorktreeID
    initial.projectID = Self.sampleProjectID
    initial.scope = .working
    initial.diffState = .error(.diffTooLarge)
    initial.worktreePathHint = nil

    let store = TestStore(initialState: initial) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.copyLargeDiffCommandRequested) // no mutation
  }

  @Test
  func fileSelectedUpdatesStateNoEffect() async {
    let store = TestStore(initialState: GitViewerFeature.State()) {
      GitViewerFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.hierarchyClient = HierarchyClient.testValue
      $0.editorClient = EditorClient.testValue
    }
    await store.send(.fileSelected("lib/foo.swift")) {
      $0.selectedFilePath = "lib/foo.swift"
    }
  }
}
