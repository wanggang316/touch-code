import Foundation
import TouchCodeCore

extension HierarchyManager {
  /// Runs the configured `git.<phase>Script` for the given Worktree
  /// headlessly via `Process`. Returns `.skipped` when the script string
  /// is nil-or-empty; otherwise spawns `$SHELL -c <command>` with cwd =
  /// the worktree's on-disk path and env = `resolvedEnv(for:in:)`.
  /// Combined stdout+stderr is captured on a single Pipe so the buffer
  /// preserves interleaving; the toast view shows it verbatim.
  ///
  /// The actual `Process.waitUntilExit` happens inside a detached Task
  /// so a long-running setup script does not block the main actor.
  func runWorktreeLifecycleScript(
    _ phase: SettingsWriter.WorktreeLifecycle,
    for worktreeID: WorktreeID,
    in projectID: ProjectID,
    settings: Settings
  ) async -> LifecycleScriptResult {
    guard let scriptCommand = Self.lifecycleScript(phase, projectID: projectID, settings: settings),
      !scriptCommand.isEmpty
    else {
      return .skipped
    }
    guard let worktreePath = path(of: worktreeID) else {
      return .skipped
    }
    let env = Self.resolvedEnv(for: projectID, in: settings)
    return await Task.detached(priority: .userInitiated) {
      Self.spawn(command: scriptCommand, cwd: worktreePath, env: env)
    }.value
  }

  /// MainActor lookup of a Worktree's on-disk path. Used by the lifecycle
  /// script runner; returns `nil` if the worktree was removed between the
  /// caller's decision and the spawn.
  private func path(of worktreeID: WorktreeID) -> String? {
    for project in catalog.projects {
      if let worktree = project.worktrees.first(where: { $0.id == worktreeID }) {
        return worktree.path
      }
    }
    return nil
  }

  /// Picks the right script string off `GitProjectSettings`. Returns nil
  /// when the project has no git settings, or when the field is unset.
  nonisolated private static func lifecycleScript(
    _ phase: SettingsWriter.WorktreeLifecycle,
    projectID: ProjectID,
    settings: Settings
  ) -> String? {
    guard let git = settings.projects[projectID]?.git else { return nil }
    switch phase {
    case .setup: return git.setupScript
    case .archive: return git.archiveScript
    case .delete: return git.deleteScript
    }
  }

  /// Spawns `$SHELL -l -c <command>` and blocks until exit. The login
  /// flag is what makes `$SHELL` source the user's `.zprofile` /
  /// `.bash_profile`, so PATH additions made there (Homebrew shellenv,
  /// `~/.local/bin`, etc.) are visible to the script. Without `-l` the
  /// child only inherits the LaunchServices-launched app's PATH —
  /// `/usr/bin:/bin:/usr/sbin:/sbin` — and any tool the user installed
  /// outside that (`claude`, `gh`, `node`, …) fails with
  /// "command not found". Same pattern `GhExecutableResolver` uses to
  /// find `gh`. Failure to launch (e.g. `$SHELL` binary missing)
  /// surfaces as `.failure(-1, _)` with the launch error description.
  nonisolated private static func spawn(
    command: String,
    cwd: String,
    env: [String: String]
  ) -> LifecycleScriptResult {
    let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    process.arguments = ["-l", "-c", command]
    process.environment = env
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      return .failure(exitCode: -1, stdout: "Failed to launch: \(error.localizedDescription)")
    }
    // `readDataToEndOfFile` blocks until both pipe write-ends close,
    // which only happens after the child process exits.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus == 0 {
      return .success(stdout: output)
    }
    return .failure(exitCode: process.terminationStatus, stdout: output)
  }

  // MARK: - Lifecycle wrappers

  /// Wraps `createWorktree` with setup-script execution. On script
  /// failure the catalog row is rolled back via `removeWorktree` so the
  /// user sees a clean "Add Worktree didn't take effect" UX. The
  /// on-disk directory is left for inspection — caller (Create Worktree
  /// flow) owns the disk-level rollback decision. Decision Log:
  /// 2026-04-25 — catalog rollback on setup failure.
  func createWorktreeWithLifecycle(
    in projectID: ProjectID,
    name: String,
    path: String,
    branch: String?,
    settings: Settings
  ) async throws -> (WorktreeID, LifecycleScriptResult) {
    let worktreeID = try createWorktree(
      in: projectID, name: name, path: path, branch: branch
    )
    let result = await runWorktreeLifecycleScript(
      .setup, for: worktreeID, in: projectID, settings: settings
    )
    if case .failure = result {
      try? removeWorktree(worktreeID, from: projectID)
    }
    return (worktreeID, result)
  }

  /// Wraps `setWorktreeArchived(true)` with archive-script execution.
  /// Fail-warn: the archived flag flips even if the script returns
  /// non-zero. Unarchive (`archived: false`) bypasses the script since
  /// the design only specifies an archive script (no unarchive hook).
  func setWorktreeArchivedWithLifecycle(
    worktreeID: WorktreeID,
    archived: Bool,
    in projectID: ProjectID,
    settings: Settings
  ) async throws -> LifecycleScriptResult {
    guard archived else {
      try setWorktreeArchived(worktreeID: worktreeID, archived: false)
      return .skipped
    }
    let result = await runWorktreeLifecycleScript(
      .archive, for: worktreeID, in: projectID, settings: settings
    )
    try setWorktreeArchived(worktreeID: worktreeID, archived: true)
    return result
  }

  /// Wraps `removeWorktree` with delete-script execution. Fail-warn:
  /// the catalog row drops regardless of script exit so the sidebar
  /// doesn't strand a row the user explicitly chose to remove.
  func removeWorktreeWithLifecycle(
    _ worktreeID: WorktreeID,
    from projectID: ProjectID,
    settings: Settings
  ) async throws -> LifecycleScriptResult {
    let result = await runWorktreeLifecycleScript(
      .delete, for: worktreeID, in: projectID, settings: settings
    )
    try removeWorktree(worktreeID, from: projectID)
    return result
  }
}
