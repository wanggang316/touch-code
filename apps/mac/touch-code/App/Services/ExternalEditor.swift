import Darwin
import Foundation
import os
import TouchCodeCore

/// Launch an external editor on a Worktree directory (or arbitrary path).
///
/// Resolves product-spec Open Q #7 per C4 D14:
/// - Built-in allowlist of 6 editors (vscode / cursor / zed / xcode /
///   subl / finder).
/// - Per-project override via `Project.defaultEditor` (set by
///   `tc project set-editor`; landing in M6.1).
/// - User-defined templates in `settings.json.externalEditors[NAME]`
///   with `%p` → path expansion (templates land in a follow-up).
/// - Invocation uses `Process` with an argv array — paths never pass
///   through a shell interpreter.
@MainActor
public final class ExternalEditor {
  public enum OpenError: Error, Equatable, Sendable {
    case worktreeNotFound(WorktreeID)
    case unknownEditor(String)
    case binaryNotFound(String)
    case spawnFailed(status: Int32, stderr: String)
  }

  public struct BuiltIn: Sendable {
    public let name: String
    public let executable: String
    public let arguments: @Sendable (String) -> [String]

    public init(
      name: String,
      executable: String,
      arguments: @escaping @Sendable (String) -> [String]
    ) {
      self.name = name
      self.executable = executable
      self.arguments = arguments
    }
  }

  public static let builtInAllowlist: [BuiltIn] = [
    BuiltIn(name: "vscode", executable: "code", arguments: { [$0] }),
    BuiltIn(name: "cursor", executable: "cursor", arguments: { [$0] }),
    BuiltIn(name: "zed", executable: "zed", arguments: { [$0] }),
    BuiltIn(name: "xcode", executable: "open", arguments: { ["-a", "Xcode", $0] }),
    BuiltIn(name: "subl", executable: "subl", arguments: { [$0] }),
    BuiltIn(name: "finder", executable: "open", arguments: { [$0] }),
  ]

  /// Fallback editor when neither the caller, the project, nor the
  /// user-supplied override named anything. `finder` is always
  /// available on macOS via `/usr/bin/open`, so this can never fail
  /// due to a missing binary — the CLI always has *something* to do.
  public static let fallbackName = "finder"

  /// Narrow protocol over `Foundation.Process` so tests can assert argv
  /// without spawning real subprocesses. `nonisolated` so a
  /// `Task.detached` can invoke it off MainActor — blocking
  /// `Process.waitUntilExit()` would otherwise stall the UI.
  public protocol ProcessRunner: Sendable {
    nonisolated func launch(executable: String, arguments: [String]) throws -> Int32
  }

  /// Default runner — uses `/usr/bin/env` to look up the executable on
  /// `$PATH`, forwards exit status.
  public struct SystemProcessRunner: ProcessRunner, Sendable {
    public init() {}
    public nonisolated func launch(executable: String, arguments: [String]) throws -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [executable] + arguments
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }
  }

  private let catalog: @MainActor () -> Catalog
  private let runner: ProcessRunner
  private let logger = Logger(subsystem: "com.touch-code.app", category: "editor")

  public init(
    catalog: @escaping @MainActor () -> Catalog,
    runner: ProcessRunner = SystemProcessRunner()
  ) {
    self.catalog = catalog
    self.runner = runner
  }

  /// Open the given Worktree's directory. `editor` takes precedence;
  /// otherwise the Project-level default, then the final `finder`
  /// fallback.
  @discardableResult
  public func open(worktreeID: WorktreeID, editor: String?) async throws -> OpenResult {
    guard let location = findWorktree(worktreeID, in: catalog()) else {
      throw OpenError.worktreeNotFound(worktreeID)
    }
    let pickedEditor = resolveEditor(
      requested: editor,
      projectDefault: location.project.defaultEditor
    )
    return try await openPath(location.worktree.path, editor: pickedEditor)
  }

  /// Open an arbitrary path in the chosen editor. The path is passed
  /// through to the editor's argv verbatim — the caller is responsible
  /// for any quoting concerns (argv is array-mode, not shell).
  @discardableResult
  public func openPath(_ path: String, editor: String?) async throws -> OpenResult {
    let name = editor ?? Self.fallbackName
    guard let entry = Self.builtInAllowlist.first(where: { $0.name == name }) else {
      throw OpenError.unknownEditor(name)
    }
    do {
      let status = try await Task.detached { [runner, entry, path] in
        try runner.launch(
          executable: entry.executable,
          arguments: entry.arguments(path)
        )
      }.value
      if status != 0 {
        throw OpenError.spawnFailed(status: status, stderr: "")
      }
      logger.debug(
        "opened \(path, privacy: .public) in \(name, privacy: .public) (status=\(status))"
      )
      return OpenResult(editor: name, path: path, exitStatus: status)
    } catch let err as OpenError {
      throw err
    } catch {
      // Most commonly: executable not found on PATH.
      throw OpenError.binaryNotFound(entry.executable)
    }
  }

  public struct OpenResult: Equatable, Sendable {
    public let editor: String
    public let path: String
    public let exitStatus: Int32
  }

  // MARK: - Helpers

  private func resolveEditor(requested: String?, projectDefault: String?) -> String {
    if let requested, !requested.isEmpty { return requested }
    if let projectDefault, !projectDefault.isEmpty { return projectDefault }
    return Self.fallbackName
  }

  private struct Location {
    let project: Project
    let worktree: Worktree
  }

  private func findWorktree(_ id: WorktreeID, in catalog: Catalog) -> Location? {
    for space in catalog.spaces {
      for project in space.projects {
        if let worktree = project.worktrees.first(where: { $0.id == id }) {
          return Location(project: project, worktree: worktree)
        }
      }
    }
    return nil
  }
}
