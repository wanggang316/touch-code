import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Covers the three `*WithLifecycle` wrappers on `HierarchyManager`.
/// Setup is fail-stop (catalog rollback on script failure); archive
/// and delete are fail-warn (state flip / row drop happens regardless).
@MainActor
struct WorktreeLifecycleWrapperTests {
  private func makeFixture(
    setupScript: String = "",
    archiveScript: String = "",
    deleteScript: String = ""
  ) throws -> (HierarchyManager, ProjectID, Settings, URL) {
    let tempBase = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    let storeURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: storeURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    let projectID = manager.addProject(name: "p", rootPath: tempBase.path, gitRoot: tempBase.path)
    var settings = Settings.default
    var project = ProjectSettings()
    var git = GitProjectSettings()
    git.createScript = setupScript.isEmpty ? nil : ScriptDefinition(command: setupScript)
    git.archiveScript = archiveScript.isEmpty ? nil : ScriptDefinition(command: archiveScript)
    git.deleteScript = deleteScript.isEmpty ? nil : ScriptDefinition(command: deleteScript)
    project.git = git
    settings.projects[projectID] = project
    return (manager, projectID, settings, tempBase)
  }

  // MARK: - createWorktreeWithLifecycle

  @Test
  func createSuccessKeepsCatalogRow() async throws {
    let (manager, projectID, settings, tempBase) = try makeFixture(
      setupScript: "/usr/bin/true"
    )
    let worktreePath = tempBase.appending(component: "wt").path
    try FileManager.default.createDirectory(
      atPath: worktreePath, withIntermediateDirectories: true
    )
    let (worktreeID, result) = try await manager.createWorktreeWithLifecycle(
      in: projectID,
      name: "wt", path: worktreePath, branch: "main",
      settings: settings
    )
    if case .success = result {
      // ok
    } else {
      Issue.record("expected .success, got \(result)")
    }
    let project = manager.catalog.projects[0]
    #expect(project.worktrees.contains(where: { $0.id == worktreeID }))
  }

  @Test
  func createFailureRollsBackCatalogRow() async throws {
    let (manager, projectID, settings, tempBase) = try makeFixture(
      setupScript: "/usr/bin/false"
    )
    let worktreePath = tempBase.appending(component: "wt-bad").path
    try FileManager.default.createDirectory(
      atPath: worktreePath, withIntermediateDirectories: true
    )
    let (worktreeID, result) = try await manager.createWorktreeWithLifecycle(
      in: projectID,
      name: "wt-bad", path: worktreePath, branch: "topic",
      settings: settings
    )
    if case .failure = result {
      // ok
    } else {
      Issue.record("expected .failure, got \(result)")
    }
    let project = manager.catalog.projects[0]
    #expect(!project.worktrees.contains(where: { $0.id == worktreeID }))
  }

  // MARK: - setWorktreeArchivedWithLifecycle

  @Test
  func archiveFailureStillFlipsArchivedFlag() async throws {
    let (manager, projectID, settings, tempBase) = try makeFixture(
      archiveScript: "/usr/bin/false"
    )
    let worktreePath = tempBase.appending(component: "wt-arch").path
    try FileManager.default.createDirectory(
      atPath: worktreePath, withIntermediateDirectories: true
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feat",
      path: worktreePath, branch: "feat"
    )
    let result = try await manager.setWorktreeArchivedWithLifecycle(
      worktreeID: worktreeID, archived: true,
      in: projectID, settings: settings
    )
    if case .failure = result {
      // expected — fail-warn semantics
    } else {
      Issue.record("expected .failure, got \(result)")
    }
    let worktree = manager.catalog.projects[0].worktrees
      .first(where: { $0.id == worktreeID })
    #expect(worktree?.archived == true)
  }

  @Test
  func archiveSkippedWhenScriptEmpty() async throws {
    let (manager, projectID, settings, tempBase) = try makeFixture(
      archiveScript: ""
    )
    let worktreePath = tempBase.appending(component: "wt-skip").path
    try FileManager.default.createDirectory(
      atPath: worktreePath, withIntermediateDirectories: true
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feat",
      path: worktreePath, branch: "feat"
    )
    let result = try await manager.setWorktreeArchivedWithLifecycle(
      worktreeID: worktreeID, archived: true,
      in: projectID, settings: settings
    )
    #expect(result == .skipped)
    let worktree = manager.catalog.projects[0].worktrees
      .first(where: { $0.id == worktreeID })
    #expect(worktree?.archived == true)
  }

  // MARK: - removeWorktreeWithLifecycle

  @Test
  func removeFailureStillDropsCatalogRow() async throws {
    let (manager, projectID, settings, tempBase) = try makeFixture(
      deleteScript: "/usr/bin/false"
    )
    let worktreePath = tempBase.appending(component: "wt-del").path
    try FileManager.default.createDirectory(
      atPath: worktreePath, withIntermediateDirectories: true
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feat",
      path: worktreePath, branch: "feat"
    )
    let result = try await manager.removeWorktreeWithLifecycle(
      worktreeID, from: projectID, settings: settings
    )
    if case .failure = result {
      // expected — fail-warn semantics
    } else {
      Issue.record("expected .failure, got \(result)")
    }
    let project = manager.catalog.projects[0]
    #expect(!project.worktrees.contains(where: { $0.id == worktreeID }))
  }

  @Test
  func removeSuccessDropsCatalogRow() async throws {
    let (manager, projectID, settings, tempBase) = try makeFixture(
      deleteScript: "/usr/bin/true"
    )
    let worktreePath = tempBase.appending(component: "wt-ok").path
    try FileManager.default.createDirectory(
      atPath: worktreePath, withIntermediateDirectories: true
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feat",
      path: worktreePath, branch: "feat"
    )
    let result = try await manager.removeWorktreeWithLifecycle(
      worktreeID, from: projectID, settings: settings
    )
    if case .success = result {
      // ok
    } else {
      Issue.record("expected .success, got \(result)")
    }
    let project = manager.catalog.projects[0]
    #expect(!project.worktrees.contains(where: { $0.id == worktreeID }))
  }
}
