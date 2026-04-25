import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Covers `HierarchyManager.runWorktreeLifecycleScript`:
/// - `.skipped` when the script is empty.
/// - `.success` / `.failure` on real `Process` exits.
/// - cwd + env propagate into the spawned shell.
@MainActor
struct WorktreeLifecycleScriptTests {
  private func makeFixture(
    setupScript: String = "",
    archiveScript: String = "",
    deleteScript: String = "",
    envVars: [String: String] = [:]
  ) throws -> (HierarchyManager, ProjectID, WorktreeID, Settings, URL) {
    let tempBase = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    let storeURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: storeURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    let spaceID = manager.createSpace(name: "s")
    let projectID = try manager.addProject(
      to: spaceID, name: "p", rootPath: tempBase.path, gitRoot: tempBase.path
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, in: spaceID, name: "feat",
      path: tempBase.path, branch: "feat"
    )
    var settings = Settings.default
    var project = ProjectSettings()
    var git = GitProjectSettings()
    git.setupScript = setupScript
    git.archiveScript = archiveScript
    git.deleteScript = deleteScript
    project.git = git
    project.envVars = envVars
    settings.projects[projectID] = project
    return (manager, projectID, worktreeID, settings, tempBase)
  }

  @Test
  func skippedWhenScriptEmpty() async throws {
    let (manager, projectID, worktreeID, settings, _) = try makeFixture(setupScript: "")
    let result = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    #expect(result == .skipped)
  }

  @Test
  func successOnZeroExit() async throws {
    let (manager, projectID, worktreeID, settings, _) = try makeFixture(
      setupScript: "/usr/bin/true"
    )
    let result = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    if case .success(let stdout) = result {
      #expect(stdout.isEmpty)
    } else {
      Issue.record("expected .success, got \(result)")
    }
  }

  @Test
  func failureOnNonZeroExit() async throws {
    let (manager, projectID, worktreeID, settings, _) = try makeFixture(
      setupScript: "/usr/bin/false"
    )
    let result = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    if case .failure(let code, _) = result {
      #expect(code == 1)
    } else {
      Issue.record("expected .failure, got \(result)")
    }
  }

  @Test
  func cwdMatchesWorktreePath() async throws {
    let (manager, projectID, worktreeID, settings, tempBase) = try makeFixture(
      setupScript: "pwd"
    )
    let result = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    if case .success(let stdout) = result {
      // macOS's `pwd` resolves /var/folders/... to /private/var/folders/...,
      // but tempBase.path retains the symlinked prefix. Match either form.
      let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = tempBase.path
      #expect(trimmed.hasSuffix(suffix), "expected pwd ending in \(suffix), got \(trimmed)")
    } else {
      Issue.record("expected .success, got \(result)")
    }
  }

  @Test
  func envVarsReachSpawnedShell() async throws {
    let (manager, projectID, worktreeID, settings, _) = try makeFixture(
      setupScript: "printf '%s' \"$MY_PROJECT_VAR\"",
      envVars: ["MY_PROJECT_VAR": "hello-from-test"]
    )
    let result = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    if case .success(let stdout) = result {
      #expect(stdout == "hello-from-test")
    } else {
      Issue.record("expected .success, got \(result)")
    }
  }

  @Test
  func archivePhaseReadsArchiveScript() async throws {
    let (manager, projectID, worktreeID, settings, _) = try makeFixture(
      archiveScript: "/usr/bin/true"
    )
    // Setup is empty → skipped; archive picks up its own script.
    let setupResult = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    let archiveResult = await manager.runWorktreeLifecycleScript(
      .archive, for: worktreeID, in: projectID, settings: settings
    )
    #expect(setupResult == .skipped)
    if case .success = archiveResult {
      // ok
    } else {
      Issue.record("expected .success, got \(archiveResult)")
    }
  }

  @Test
  func failureCaptureMergesStderr() async throws {
    let (manager, projectID, worktreeID, settings, _) = try makeFixture(
      setupScript: "echo out; echo err 1>&2; exit 7"
    )
    let result = await manager.runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    if case .failure(let code, let stdout) = result {
      #expect(code == 7)
      #expect(stdout.contains("out"))
      #expect(stdout.contains("err"))
    } else {
      Issue.record("expected .failure, got \(result)")
    }
  }
}
