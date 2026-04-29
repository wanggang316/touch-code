import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Tests for `DiffFeature` — covers the selection → changed-files load,
/// per-file diff load with cache, drawer-close cache survival, style
/// changes, and over-cap handling. The reducer's filesystem reads
/// (`String(contentsOf:)` for the working-tree side) are exercised against
/// a per-test temp directory so the cap-checking logic runs end-to-end
/// rather than via an additional injection seam.
@MainActor
struct DiffFeatureTests {
  // MARK: - Fixtures

  private static func makeTempWorktree(
    files: [String: String] = [:]
  ) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("DiffFeatureTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (path, contents) in files {
      let fileURL = url.appendingPathComponent(path)
      try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return url
  }

  private static func sampleChangedFile(path: String) -> ChangedFile {
    ChangedFile(
      oldPath: path, newPath: path, status: .modified,
      addedLines: 1, removedLines: 1, isBinary: false
    )
  }

  // MARK: - Happy path: worktreeSelected → changedFilesSucceeded

  @Test
  func worktreeSelectedKicksChangedFilesLoadAndStoresResult() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let worktree = Self.makeTempWorktree()
    let files: [ChangedFile] = [
      Self.sampleChangedFile(path: "a.swift"),
      Self.sampleChangedFile(path: "b.swift"),
      Self.sampleChangedFile(path: "c.swift"),
    ]

    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.diffNumstat = { _ in files }
    }

    await store.send(
      .worktreeSelected(
        projectID: projectID, worktreeID: worktreeID, path: worktree.path
      )
    ) { state in
      state.projectID = projectID
      state.worktreeID = worktreeID
      state.worktreePath = worktree.path
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesSucceeded(files)) { state in
      state.changedFiles = .loaded(files)
    }
  }

  // MARK: - Per-file load + cache

  @Test
  func fileRowTappedLoadsAndCachesDiff() async {
    let worktree = Self.makeTempWorktree(files: [
      "a.swift": "new contents\n"
    ])

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: worktree.path,
        changedFiles: .loaded([Self.sampleChangedFile(path: "a.swift")])
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.showFileAtHEAD = { _, _ in "old contents\n" }
    }

    await store.send(.fileRowTapped(path: "a.swift")) { state in
      state.presentedFilePath = "a.swift"
      state.diffsByPath["a.swift"] = .loading
    }
    let expectedDocument = DiffDocument(
      files: [
        DiffFile(
          oldPath: "a.swift", newPath: "a.swift",
          oldContents: "old contents\n", newContents: "new contents\n"
        )
      ],
      title: "a.swift"
    )
    await store.receive(.diffSucceededFor(path: "a.swift", document: expectedDocument)) {
      state in
      state.diffsByPath["a.swift"] = .loaded(expectedDocument)
    }

    // Re-tapping the open row is a no-op (chevron / × own the close path).
    await store.send(.fileRowTapped(path: "a.swift"))
  }

  // MARK: - Cancel on worktreeSelected

  @Test
  func worktreeSelectedDuringInflightLoadCancelsPriorEffect() async {
    let projectA = ProjectID()
    let worktreeA = WorktreeID()
    let pathA = Self.makeTempWorktree().path

    let projectB = ProjectID()
    let worktreeB = WorktreeID()
    let pathB = Self.makeTempWorktree().path

    let filesB: [ChangedFile] = [Self.sampleChangedFile(path: "z.swift")]

    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      // First load hangs forever; second resolves immediately.
      $0.gitService.diffNumstat = { path in
        if path == pathA {
          // Hang until cancelled — cooperative cancellation drops us out.
          try? await Task.sleep(nanoseconds: 60_000_000_000)
          throw GitError.timedOut
        }
        return filesB
      }
    }

    await store.send(
      .worktreeSelected(projectID: projectA, worktreeID: worktreeA, path: pathA)
    ) { state in
      state.projectID = projectA
      state.worktreeID = worktreeA
      state.worktreePath = pathA
      state.changedFiles = .loading
    }

    // Switching Worktrees cancels the prior `diffNumstat` and starts a fresh one.
    await store.send(
      .worktreeSelected(projectID: projectB, worktreeID: worktreeB, path: pathB)
    ) { state in
      state.projectID = projectB
      state.worktreeID = worktreeB
      state.worktreePath = pathB
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesSucceeded(filesB)) { state in
      state.changedFiles = .loaded(filesB)
    }
  }

  // MARK: - Drawer close

  @Test
  func drawerCloseRequestedClearsPresentationButKeepsCache() async {
    let cachedDoc = DiffDocument(
      files: [
        DiffFile(
          oldPath: "a.swift", newPath: "a.swift",
          oldContents: "old", newContents: "new"
        )
      ],
      title: "a.swift"
    )
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: "/tmp",
        presentedFilePath: "a.swift",
        diffsByPath: ["a.swift": .loaded(cachedDoc)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.drawerCloseRequested) { state in
      state.presentedFilePath = nil
    }
    #expect(store.state.diffsByPath["a.swift"] == .loaded(cachedDoc))
  }

  // MARK: - Style change

  @Test
  func styleChangedUpdatesState() async {
    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }
    await store.send(.styleChanged(.split)) { state in
      state.style = .split
    }
  }

  // MARK: - Too-large

  @Test
  func oversizedFileSurfacesAsTooLargeWithCopyCommand() async {
    // Build a 600 KB working-tree file to trip the byteCount cap.
    let big = String(repeating: "x", count: 600_000)
    let worktree = Self.makeTempWorktree(files: ["big.swift": big])

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: worktree.path,
        changedFiles: .loaded([Self.sampleChangedFile(path: "big.swift")])
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.showFileAtHEAD = { _, _ in "" }
    }

    let expectedCmd = "cd '\(worktree.path)' && git diff 'big.swift'"
    await store.send(.fileRowTapped(path: "big.swift")) { state in
      state.presentedFilePath = "big.swift"
      state.diffsByPath["big.swift"] = .loading
    }
    await store.receive(
      .diffTooLargeFor(
        path: "big.swift",
        reason: .byteCount(600_000),
        copyCommand: expectedCmd
      )
    ) { state in
      state.diffsByPath["big.swift"] = .tooLarge(
        reason: .byteCount(600_000), copyCommand: expectedCmd)
    }
  }
}
