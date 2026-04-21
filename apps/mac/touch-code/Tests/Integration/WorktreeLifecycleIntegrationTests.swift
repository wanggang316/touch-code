import Foundation
import Testing
@testable import touch_code

/// End-to-end test against a real temp git repo + the bundled `wt`
/// script. Exercises the full worktree lifecycle — create via
/// `createWorktreeStream`, list via `lsWorktrees`, safe-remove,
/// force-remove after dirtying the tree, plus the uncommittedChanges
/// error path.
///
/// Skipped when the bundled `wt` resource cannot be resolved (dev
/// builds that haven't run `embed-git-wt.sh` yet). The app build's
/// Tuist pre-script (`verify-git-wt.sh`) normally guarantees it is
/// present; this guard is belt-and-braces for headless test hosts.
@MainActor
struct WorktreeLifecycleIntegrationTests {
  private let fm = FileManager.default

  private func makeTempRepo() async throws -> URL {
    let base = fm.temporaryDirectory
      .appending(path: "touch-code-wt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    // git init + initial commit so `wt sw --from HEAD` has something to branch from.
    try runGit(["init", "-q", "-b", "main"], cwd: base)
    try runGit(["config", "user.email", "test@example.com"], cwd: base)
    try runGit(["config", "user.name", "test"], cwd: base)
    try "hello".write(
      to: base.appending(path: "README.md"), atomically: true, encoding: .utf8
    )
    try runGit(["add", "README.md"], cwd: base)
    try runGit(["commit", "-q", "-m", "init"], cwd: base)
    return base
  }

  private func runGit(_ args: [String], cwd: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = cwd
    p.environment = ProcessInfo.processInfo.environment
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func wtAvailable() -> Bool {
    Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt") != nil
  }

  @Test
  func fullLifecycle() async throws {
    try #require(wtAvailable(), "wt script not bundled in test target")
    let repo = try await makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()

    // Create a worktree via the streaming path.
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "feature-a",
      branch: "feature-a",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .finished(let path) = event { createdPath = path }
    }
    let worktreePath = try #require(createdPath)
    #expect(fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))

    // List — should include main + feature-a, neither bare.
    let entries = try await client.lsWorktrees(repo)
    #expect(entries.count == 2)
    #expect(entries.allSatisfy { !$0.isBare })
    #expect(entries.contains(where: { $0.branch == "feature-a" }))

    // Safe-remove the clean worktree.
    try await client.removeWorktree(repo, worktreePath, false)
    let afterRemove = try await client.lsWorktrees(repo)
    #expect(afterRemove.count == 1)
  }

  @Test
  func uncommittedChangesBlockSafeRemoveAndForceRemoveSucceeds() async throws {
    try #require(wtAvailable(), "wt script not bundled in test target")
    let repo = try await makeTempRepo()
    defer { try? fm.removeItem(at: repo) }

    let client = GitWorktreeClient.makeLive()
    let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let spec = CreateWorktreeSpec(
      repoRoot: repo,
      baseDirectory: baseDir,
      name: "dirty",
      branch: "dirty",
      baseRef: "HEAD",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    var createdPath: URL?
    for try await event in client.createWorktreeStream(spec) {
      if case .finished(let path) = event { createdPath = path }
    }
    let worktreePath = try #require(createdPath)

    // Write a new file so the worktree has an untracked/uncommitted file.
    let dirty = worktreePath.appending(path: "uncommitted.txt")
    try "x".write(to: dirty, atomically: true, encoding: .utf8)
    try runGit(["add", "uncommitted.txt"], cwd: worktreePath)

    // Safe-remove fails with .uncommittedChanges.
    var caught: GitWorktreeError?
    do {
      try await client.removeWorktree(repo, worktreePath, false)
    } catch let err as GitWorktreeError {
      caught = err
    }
    #expect(caught != nil)
    if case .uncommittedChanges(let files)? = caught {
      #expect(!files.isEmpty)
    } else {
      Issue.record("expected .uncommittedChanges, got \(String(describing: caught))")
    }

    // Force remove succeeds.
    try await client.removeWorktree(repo, worktreePath, true)
    #expect(!fm.fileExists(atPath: worktreePath.path(percentEncoded: false)))
  }
}
