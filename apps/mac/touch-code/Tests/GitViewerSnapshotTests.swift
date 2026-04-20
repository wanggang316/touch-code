import AppKit
import ComposableArchitecture
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import TouchCodeCore
@testable import touch_code

/// Visual regression tests for the C7 git viewer. Six fixture snapshots cover the happy-path
/// render states plus the two error surfaces the plan flags (`.diffTooLarge` placeholder +
/// `.exec` error in the file list).
///
/// **Gating + deferred reference PNGs (DEC-20).** The test infrastructure is wired in M4b
/// (SnapshotTesting dep in `Tuist/Package.swift`, NSHostingView wrap, fixture generators).
/// Reference PNGs are **not** checked in yet because `NSHostingView` without a presentation
/// window crashes when rendering `List` + `@FocusState` (both of which the file-list uses).
/// The record pass needs either:
///   (a) an `NSWindow`-hosted presentation context in the harness, or
///   (b) a refactor that snapshots individual column views instead of the composite viewer.
/// Either is M4b.1 follow-up work. Until then tests are env-gated
/// (`TC_RUN_SNAPSHOT_TESTS=1`) and skip cleanly in default runs; enabling them surfaces
/// "no reference image" failures that guide the record pass.
@MainActor
struct GitViewerSnapshotTests {
  nonisolated static let snapshotsEnabled: Bool = {
    ProcessInfo.processInfo.environment["TC_RUN_SNAPSHOT_TESTS"] == "1"
  }()

  nonisolated static let inspectorSize = CGSize(width: 480, height: 640)

  // MARK: - Happy paths

  @Test(.enabled(if: GitViewerSnapshotTests.snapshotsEnabled))
  func logScopePopulated() {
    var state = GitViewerFeature.State()
    state.worktreeID = Self.fixtureWorktreeID
    state.projectID = Self.fixtureProjectID
    state.worktreePathHint = Self.fixturePath
    state.scope = .log
    state.logState = .loaded(Self.fixtureLogPage(count: 8))

    let hosting = Self.makeHostingView(state: state)
    assertSnapshot(of: hosting, as: .image)
  }

  @Test(.enabled(if: GitViewerSnapshotTests.snapshotsEnabled))
  func workingScopeWithTenFiles() {
    var state = GitViewerFeature.State()
    state.worktreeID = Self.fixtureWorktreeID
    state.projectID = Self.fixtureProjectID
    state.worktreePathHint = Self.fixturePath
    state.scope = .working
    state.diffState = .loaded(Self.fixtureWorkingDiff(fileCount: 10))
    state.selectedFilePath = "src/parser.swift"

    let hosting = Self.makeHostingView(state: state)
    assertSnapshot(of: hosting, as: .image)
  }

  @Test(.enabled(if: GitViewerSnapshotTests.snapshotsEnabled))
  func commitScopeWithRenameBinaryAndAddedFile() {
    var state = GitViewerFeature.State()
    state.worktreeID = Self.fixtureWorktreeID
    state.projectID = Self.fixtureProjectID
    state.worktreePathHint = Self.fixturePath
    state.scope = .commit(sha: "deadbee")
    state.diffState = .loaded(Self.fixtureCommitDiff())
    state.selectedFilePath = "src/renamed.swift"

    let hosting = Self.makeHostingView(state: state)
    assertSnapshot(of: hosting, as: .image)
  }

  @Test(.enabled(if: GitViewerSnapshotTests.snapshotsEnabled))
  func notARepoEmptyState() {
    var state = GitViewerFeature.State()
    state.worktreeID = Self.fixtureWorktreeID
    state.projectID = Self.fixtureProjectID
    state.worktreePathHint = Self.fixturePath
    state.scope = .working
    state.diffState = .error(.notARepo)

    let hosting = Self.makeHostingView(state: state)
    assertSnapshot(of: hosting, as: .image)
  }

  // MARK: - Error paths

  @Test(.enabled(if: GitViewerSnapshotTests.snapshotsEnabled))
  func largeDiffPlaceholderWithPathContainingSpace() {
    var state = GitViewerFeature.State()
    state.worktreeID = Self.fixtureWorktreeID
    state.projectID = Self.fixtureProjectID
    state.worktreePathHint = "/tmp/with space/repo"
    state.scope = .working
    state.diffState = .error(.diffTooLarge)

    let hosting = Self.makeHostingView(state: state)
    assertSnapshot(of: hosting, as: .image)
  }

  @Test(.enabled(if: GitViewerSnapshotTests.snapshotsEnabled))
  func execErrorToastInFileList() {
    var state = GitViewerFeature.State()
    state.worktreeID = Self.fixtureWorktreeID
    state.projectID = Self.fixtureProjectID
    state.worktreePathHint = Self.fixturePath
    state.scope = .working
    state.diffState = .error(.exec(code: 1, stderr: "fatal: unable to read current working directory"))

    let hosting = Self.makeHostingView(state: state)
    assertSnapshot(of: hosting, as: .image)
  }

  // MARK: - Fixtures + helpers

  nonisolated static let fixtureSpaceID = SpaceID()
  nonisolated static let fixtureProjectID = ProjectID()
  nonisolated static let fixtureWorktreeID = WorktreeID()
  nonisolated static let fixturePath = "/Users/snapshot/repo"

  /// Wraps the SwiftUI `GitViewerView` in an `NSHostingView` sized to the inspector so
  /// `SnapshotTesting` (macOS `NSView` → `.image` strategy) can render it. The reducer is
  /// a no-op so effects never fire during snapshot capture; state is baked in by the
  /// caller.
  @MainActor static func makeHostingView(state: GitViewerFeature.State) -> NSHostingView<some View> {
    let store = Store(initialState: state) {
      Reduce<GitViewerFeature.State, GitViewerFeature.Action> { _, _ in .none }
    }
    let view = GitViewerView(store: store)
      .frame(width: inspectorSize.width, height: inspectorSize.height)
      .background(Color(nsColor: .windowBackgroundColor))
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: inspectorSize)
    return hosting
  }

  nonisolated static func fixtureLogPage(count: Int) -> LogPage {
    let commits = (0..<count).map { idx -> Commit in
      let hash = String(format: "%040x", 0xABCDEF0 + idx)
      return Commit(
        id: hash,
        authorName: idx.isMultiple(of: 2) ? "Gump" : "Claude",
        authorEmail: "dev@example.com",
        date: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(idx * 3600)),
        subject: "commit #\(idx) — sample subject to render",
        parents: idx == 0 ? [] : [String(format: "%040x", 0xABCDEF0 + idx - 1)]
      )
    }
    return LogPage(cursor: .init(offset: 0, limit: 100), commits: commits, hasMore: false)
  }

  nonisolated static func fixtureWorkingDiff(fileCount: Int) -> UnifiedDiff {
    let files = (0..<fileCount).map { idx -> FileChange in
      FileChange(
        id: "src/\(["parser", "lexer", "ast", "types", "driver", "util", "codec", "net", "ui", "tests"][idx % 10]).swift",
        kind: idx == 0 ? .added : (idx == 1 ? .deleted : .modified),
        isBinary: false,
        linesAdded: idx * 3 + 1,
        linesRemoved: idx * 2,
        hunks: [
          DiffHunk(
            header: "@@ -1,3 +1,4 @@",
            oldStart: 1, oldCount: 3, newStart: 1, newCount: 4,
            lines: [
              DiffLine(kind: .context, text: " context line in file \(idx)"),
              DiffLine(kind: .removed, text: "-old content #\(idx)"),
              DiffLine(kind: .added, text: "+new content #\(idx)"),
              DiffLine(kind: .added, text: "+added companion line"),
              DiffLine(kind: .context, text: " trailing context"),
            ]
          )
        ]
      )
    }
    return UnifiedDiff(scope: .working, files: files)
  }

  nonisolated static func fixtureCommitDiff() -> UnifiedDiff {
    let renamed = FileChange(
      id: "src/renamed.swift",
      kind: .renamed(from: "src/old_name.swift"),
      isBinary: false,
      linesAdded: 2, linesRemoved: 2,
      hunks: [
        DiffHunk(
          header: "@@ -10,3 +10,3 @@ func example() {",
          oldStart: 10, oldCount: 3, newStart: 10, newCount: 3,
          lines: [
            DiffLine(kind: .context, text: " unchanged context"),
            DiffLine(kind: .removed, text: "-old implementation"),
            DiffLine(kind: .added, text: "+new implementation"),
            DiffLine(kind: .removed, text: "-another old line"),
            DiffLine(kind: .added, text: "+another new line"),
          ]
        )
      ]
    )
    let binary = FileChange(
      id: "assets/logo.png",
      kind: .modified,
      isBinary: true,
      linesAdded: 0, linesRemoved: 0,
      hunks: []
    )
    let added = FileChange(
      id: "docs/new-feature.md",
      kind: .added,
      isBinary: false,
      linesAdded: 4, linesRemoved: 0,
      hunks: [
        DiffHunk(
          header: "@@ -0,0 +1,4 @@",
          oldStart: 0, oldCount: 0, newStart: 1, newCount: 4,
          lines: (1...4).map { i in DiffLine(kind: .added, text: "+line \(i) of the new doc") }
        )
      ]
    )
    return UnifiedDiff(scope: .commit(sha: "deadbee"), files: [renamed, binary, added])
  }
}
