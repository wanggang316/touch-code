import ComposableArchitecture
import Foundation

// MARK: - Public value types

/// JSON shape returned by `wt ls --json`. Field names match the upstream
/// `git-wt` output; `is_bare` maps to `isBare` via `CodingKeys`.
nonisolated struct GitWtEntry: Decodable, Equatable, Sendable {
  let branch: String
  let path: String
  let head: String
  let isBare: Bool

  enum CodingKeys: String, CodingKey {
    case branch, path, head
    case isBare = "is_bare"
  }
}

/// Input spec for `createWorktreeStream`. The caller pre-sanitizes `name`
/// to the on-disk directory name (via `GitWorktreeClient.sanitizeBranchName`
/// or an equivalent), which may differ from `branch` when the branch name
/// contains characters that aren't safe as a directory name.
nonisolated struct CreateWorktreeSpec: Equatable, Sendable {
  var repoRoot: URL
  var baseDirectory: URL
  var name: String
  var branch: String
  var baseRef: String
  var fetchOrigin: Bool
  var copyIgnored: Bool
  var copyUntracked: Bool
}

/// Stream events emitted while `wt sw` runs. Consumers render
/// `.progressLine` verbatim in the Create sheet's log area; `.finished`
/// signals completion and carries the newly-created worktree path.
nonisolated enum CreateWorktreeEvent: Equatable, Sendable {
  case progressLine(String)
  case finished(worktreePath: URL)
}

/// Typed errors surfaced by `GitWorktreeClient`. UI-visible cases
/// (`.uncommittedChanges`, `.branchExists`, `.invalidBranchName`, etc.)
/// drive tailored dialogs; `.commandFailed` is the catch-all that
/// round-trips the underlying git command + stderr.
nonisolated enum GitWorktreeError: Error, Equatable, Sendable {
  case executableMissing
  case branchExists(String)
  case invalidBranchName(String)
  case refNotFound(String)
  case fetchFailed(String)
  case uncommittedChanges(files: [String])
  case worktreeLocked(String)
  case commandFailed(command: String, stderr: String)
}

// MARK: - Client

/// Async-closures dependency covering the worktree-management spec's git
/// surface. Wraps the bundled `wt` script (for `ls --json`, streaming
/// create) plus a few complementary `/usr/bin/git` invocations (ref
/// queries, `worktree remove`, `worktree prune`, `fetch`). Closures run
/// off the main actor; callers `await` at call sites.
///
/// The live implementation is filled in by a later milestone; this type
/// scaffolds the shape so features and tests can link it now.
nonisolated struct GitWorktreeClient: Sendable {
  var lsWorktrees: @Sendable (_ repoRoot: URL) async throws -> [GitWtEntry]
  var localBranchNames: @Sendable (_ repoRoot: URL) async throws -> Set<String>
  var branchRefs: @Sendable (_ repoRoot: URL) async throws -> [String]
  var defaultRemoteBranchRef: @Sendable (_ repoRoot: URL) async throws -> String?
  var isValidBranchName: @Sendable (_ repoRoot: URL, _ name: String) async -> Bool

  var createWorktreeStream: @Sendable (_ spec: CreateWorktreeSpec)
    -> AsyncThrowingStream<CreateWorktreeEvent, Error>

  var removeWorktree: @Sendable (
    _ repoRoot: URL, _ path: URL, _ force: Bool
  ) async throws -> Void
  var pruneWorktrees: @Sendable (_ repoRoot: URL) async throws -> Int

  var fetchRemote: @Sendable (_ repoRoot: URL, _ remote: String) async throws -> Void
  var changedFiles: @Sendable (_ worktreeRoot: URL) async throws -> [String]
}

// MARK: - Pure helpers (visible for tests)

nonisolated extension GitWorktreeClient {
  /// Derives a filesystem-safe directory name from a branch name. Replaces
  /// `/` with `-`, strips characters that break on macOS filesystems (`\0`,
  /// `:`), collapses consecutive `-` runs, and trims leading/trailing
  /// dashes. Intentionally conservative; a collision with an existing
  /// directory is a hard error at create time (W-Q5) rather than being
  /// silently suffixed.
  static func sanitizeBranchName(_ branch: String) -> String {
    var scalars: [Character] = []
    for ch in branch {
      switch ch {
      case "/":
        scalars.append("-")
      case "\0", ":", "\\":
        continue
      default:
        scalars.append(ch)
      }
    }
    let replaced = String(scalars)
    // Collapse repeated dashes.
    var collapsed = ""
    var lastWasDash = false
    for ch in replaced {
      if ch == "-" {
        if !lastWasDash { collapsed.append(ch) }
        lastWasDash = true
      } else {
        collapsed.append(ch)
        lastWasDash = false
      }
    }
    // Trim leading/trailing dashes.
    while collapsed.first == "-" { collapsed.removeFirst() }
    while collapsed.last == "-" { collapsed.removeLast() }
    return collapsed
  }

  /// Constructs the `wt` argv for a streaming `sw` (switch-and-create)
  /// invocation. Mirrors supacode's `createWorktreeArguments` — order
  /// matters for the helper's own parsing.
  static func makeCreateArguments(for spec: CreateWorktreeSpec) -> [String] {
    var arguments = ["--base-dir", spec.baseDirectory.path(percentEncoded: false), "sw"]
    if spec.copyIgnored { arguments.append("--copy-ignored") }
    if spec.copyUntracked { arguments.append("--copy-untracked") }
    if !spec.baseRef.isEmpty {
      arguments.append("--from")
      arguments.append(spec.baseRef)
    }
    if spec.copyIgnored || spec.copyUntracked {
      arguments.append("--verbose")
    }
    arguments.append(spec.name)
    return arguments
  }

  /// Heuristic-maps `git worktree remove` stderr onto the typed error
  /// cases. Unknown patterns fall through to `.commandFailed`. Callers
  /// that need `.uncommittedChanges(files:)` populate `files` from
  /// `git status --porcelain` separately.
  static func mapGitStderr(command: String, stderr: String) -> GitWorktreeError {
    let lower = stderr.lowercased()
    if let match = stderr.firstMatch(of: /A branch named '([^']+)' already exists/) {
      return .branchExists(String(match.1))
    }
    if let match = stderr.firstMatch(of: /'([^']+)' is not a valid branch name/) {
      return .invalidBranchName(String(match.1))
    }
    if lower.contains("unknown revision") || lower.contains("bad revision") {
      return .refNotFound(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains("is locked") {
      return .worktreeLocked(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains("contains modified or untracked files") {
      return .uncommittedChanges(files: [])
    }
    return .commandFailed(
      command: command,
      stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Parses `git status --porcelain` output into a list of file paths.
  /// Strips the two-character status prefix (XY) plus the following space.
  /// Index arithmetic is byte-safe: we drop a fixed three-byte prefix from
  /// the UTF-8 view rather than stepping `String.Index` to avoid any
  /// surprises with composed characters in file names.
  static func parsePorcelainPaths(_ output: String) -> [String] {
    var paths: [String] = []
    for rawLine in output.components(separatedBy: "\n") {
      guard rawLine.utf8.count >= 4 else { continue }
      let utf8 = rawLine.utf8
      let start = utf8.index(utf8.startIndex, offsetBy: 3)
      guard let trimmed = String(utf8[start...])?.trimmingCharacters(in: .whitespaces),
            !trimmed.isEmpty else { continue }
      paths.append(trimmed)
    }
    return paths
  }
}

// MARK: - Live implementation helpers

/// Resolves the bundled `wt` script out of the app bundle's Resources
/// folder. Debug and Release builds alike embed the script via Tuist's
/// post-build `embed-git-wt.sh` (see `apps/mac/scripts/`).
nonisolated func wtScriptURL() throws -> URL {
  guard let url = Bundle.main.url(
    forResource: "wt", withExtension: nil, subdirectory: "git-wt"
  ) else {
    throw GitWorktreeError.executableMissing
  }
  return url
}

/// Shell-out primitives used by `GitWorktreeClient.makeLive`. Kept at
/// file scope rather than as struct statics so tests can mock them per
/// closure if needed — unused by default because the M13 integration
/// test exercises the real live implementation.
nonisolated enum GitWorktreeShell {
  static let runner = FoundationCommandRunner()
  static let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  /// 60 s covers the slowest non-copy git operation we issue. Streaming
  /// `wt sw` bypasses this limit by using its own pipe-driven runner.
  static let defaultTimeout: Duration = .seconds(60)
  static let maxOutputBytes = 4 * 1024 * 1024

  /// One-shot invocation returning captured stdout/stderr.
  static func run(
    executable: URL, arguments: [String], cwd: URL
  ) async -> CommandOutcome {
    await runner.run(
      executable: executable,
      arguments: arguments,
      env: ProcessInfo.processInfo.environment,
      cwd: cwd,
      timeout: defaultTimeout,
      maxOutputBytes: maxOutputBytes
    )
  }

  /// Decodes stdout bytes to UTF-8, returning `""` on decode failure so
  /// the caller gets a deterministic empty result rather than a throw.
  static func decodeUTF8(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
  }

  /// Low-level streaming runner for `wt sw` — spawns a `Process`, wires
  /// per-line stdout/stderr handlers, and yields line-level events until
  /// the child exits. On success the final event is
  /// `.exited(code, stderr)`.
  static func runStream(
    executable: URL,
    arguments: [String],
    cwd: URL,
    onStdout: @escaping @Sendable (String) -> Void,
    onStderr: @escaping @Sendable (String) -> Void
  ) async -> (exitCode: Int32, stdoutLast: String, stderrCollected: String, spawnFailedReason: String?) {
    await withCheckedContinuation { cont in
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.currentDirectoryURL = cwd
      process.environment = ProcessInfo.processInfo.environment
      process.standardInput = FileHandle.nullDevice

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      // Box mutable line buffers so the Sendable readability handlers can
      // accumulate partial lines across reads without data races.
      final class LineBuffer: @unchecked Sendable {
        var buffer = ""
        var lastNonEmpty = ""
      }
      let stdoutState = LineBuffer()
      let stderrState = LineBuffer()
      let stdoutLock = NSLock()
      let stderrLock = NSLock()

      stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) else { return }
        stdoutLock.lock()
        stdoutState.buffer += str
        var lines: [String] = []
        while let nl = stdoutState.buffer.firstIndex(of: "\n") {
          let line = String(stdoutState.buffer[..<nl])
          stdoutState.buffer.removeSubrange(...nl)
          lines.append(line)
        }
        for line in lines {
          let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { stdoutState.lastNonEmpty = trimmed }
        }
        stdoutLock.unlock()
        for line in lines { onStdout(line) }
      }
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) else { return }
        stderrLock.lock()
        stderrState.buffer += str
        var lines: [String] = []
        while let nl = stderrState.buffer.firstIndex(of: "\n") {
          let line = String(stderrState.buffer[..<nl])
          stderrState.buffer.removeSubrange(...nl)
          lines.append(line)
        }
        stderrLock.unlock()
        for line in lines { onStderr(line) }
      }

      process.terminationHandler = { proc in
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain any trailing bytes that did not end in a newline.
        let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailOut.isEmpty, let str = String(data: tailOut, encoding: .utf8) {
          stdoutLock.lock()
          let combined = stdoutState.buffer + str
          stdoutState.buffer = ""
          let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { stdoutState.lastNonEmpty = trimmed }
          stdoutLock.unlock()
          onStdout(combined)
        }
        let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailErr.isEmpty, let str = String(data: tailErr, encoding: .utf8) {
          stderrLock.lock()
          stderrState.buffer += str
          stderrLock.unlock()
          onStderr(str)
        }
        stdoutLock.lock()
        let finalLastNonEmpty = stdoutState.lastNonEmpty
        stdoutLock.unlock()
        stderrLock.lock()
        let finalStderr = stderrState.buffer
        stderrLock.unlock()
        cont.resume(returning: (
          exitCode: proc.terminationStatus,
          stdoutLast: finalLastNonEmpty,
          stderrCollected: finalStderr,
          spawnFailedReason: nil
        ))
      }

      do {
        try process.run()
      } catch {
        cont.resume(returning: (
          exitCode: -1,
          stdoutLast: "",
          stderrCollected: "",
          spawnFailedReason: error.localizedDescription
        ))
      }
    }
  }
}

nonisolated extension GitWorktreeClient {
  // Binds every closure to a live `wt`/`git` invocation. Used from
  // `TouchCodeApp.bringUp()` at startup.
  //
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func makeLive() -> GitWorktreeClient {
    GitWorktreeClient(
      lsWorktrees: { repoRoot in
        let wt = try wtScriptURL()
        let outcome = await GitWorktreeShell.run(
          executable: wt, arguments: ["ls", "--json"], cwd: repoRoot
        )
        switch outcome {
        case .exited(let code, let stdout, let stderr, _):
          guard code == 0 else {
            throw GitWorktreeError.commandFailed(
              command: "wt ls --json",
              stderr: GitWorktreeShell.decodeUTF8(stderr)
            )
          }
          let trimmed = GitWorktreeShell.decodeUTF8(stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return [] }
          let entries = try JSONDecoder().decode([GitWtEntry].self, from: Data(trimmed.utf8))
          return entries.filter { !$0.isBare }
        case .timedOut:
          throw GitWorktreeError.commandFailed(command: "wt ls --json", stderr: "timed out")
        case .spawnFailed(let reason):
          throw GitWorktreeError.commandFailed(command: "wt ls --json", stderr: reason)
        }
      },

      localBranchNames: { repoRoot in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "for-each-ref", "--format=%(refname:short)", "refs/heads",
          ],
          cwd: repoRoot
        )
        let stdout = try extractStdout(outcome, command: "git for-each-ref refs/heads")
        return Set(
          stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        )
      },

      branchRefs: { repoRoot in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes",
          ],
          cwd: repoRoot
        )
        let stdout = try extractStdout(outcome, command: "git for-each-ref refs/heads refs/remotes")
        return
          stdout
          .components(separatedBy: "\n")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
      },

      defaultRemoteBranchRef: { repoRoot in
        // Try symbolic-ref first (fast; succeeds when `origin/HEAD` is set locally).
        let symbolic = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
          ],
          cwd: repoRoot
        )
        if case .exited(let code, let data, _, _) = symbolic, code == 0 {
          let trimmed = GitWorktreeShell.decodeUTF8(data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { return trimmed }
        }
        // Fallback: parse `git remote show origin` for "HEAD branch: X".
        let show = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "remote", "show", "origin",
          ],
          cwd: repoRoot
        )
        if case .exited(let code, let data, _, _) = show, code == 0 {
          let text = GitWorktreeShell.decodeUTF8(data)
          for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("HEAD branch:") {
              let branch = trimmed
                .dropFirst("HEAD branch:".count)
                .trimmingCharacters(in: .whitespaces)
              if !branch.isEmpty && branch != "(unknown)" {
                return "origin/\(branch)"
              }
            }
          }
        }
        return nil
      },

      isValidBranchName: { repoRoot, name in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "check-ref-format", "--branch", name,
          ],
          cwd: repoRoot
        )
        if case .exited(let code, _, _, _) = outcome, code == 0 {
          return true
        }
        return false
      },

      createWorktreeStream: { spec in
        AsyncThrowingStream { continuation in
          let task = Task {
            do {
              let wt = try wtScriptURL()
              // Optional pre-fetch.
              if spec.fetchOrigin {
                let fetch = await GitWorktreeShell.run(
                  executable: GitWorktreeShell.gitURL,
                  arguments: [
                    "-C", spec.repoRoot.path(percentEncoded: false),
                    "fetch", "origin",
                  ],
                  cwd: spec.repoRoot
                )
                if case .exited(let code, _, let err, _) = fetch, code != 0 {
                  continuation.finish(throwing: GitWorktreeError.fetchFailed(
                    GitWorktreeShell.decodeUTF8(err)
                      .trimmingCharacters(in: .whitespacesAndNewlines)
                  ))
                  return
                }
              }

              let args = makeCreateArguments(for: spec)
              let outcome = await GitWorktreeShell.runStream(
                executable: wt,
                arguments: args,
                cwd: spec.repoRoot,
                onStdout: { line in continuation.yield(.progressLine(line)) },
                onStderr: { line in continuation.yield(.progressLine(line)) }
              )
              if let reason = outcome.spawnFailedReason {
                continuation.finish(throwing: GitWorktreeError.commandFailed(
                  command: "wt \(args.joined(separator: " "))",
                  stderr: reason
                ))
                return
              }
              guard outcome.exitCode == 0 else {
                let command = "wt \(args.joined(separator: " "))"
                continuation.finish(throwing: mapGitStderr(
                  command: command,
                  stderr: outcome.stderrCollected
                ))
                return
              }
              let pathString = outcome.stdoutLast
              guard !pathString.isEmpty else {
                continuation.finish(throwing: GitWorktreeError.commandFailed(
                  command: "wt \(args.joined(separator: " "))",
                  stderr: "wt exited 0 without reporting a worktree path"
                ))
                return
              }
              let worktreeURL = URL(fileURLWithPath: pathString).standardizedFileURL
              continuation.yield(.finished(worktreePath: worktreeURL))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },

      removeWorktree: { repoRoot, path, force in
        var args = [
          "-C", repoRoot.path(percentEncoded: false),
          "worktree", "remove",
        ]
        if force { args.append("--force") }
        args.append(path.path(percentEncoded: false))
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: args,
          cwd: repoRoot
        )
        switch outcome {
        case .exited(let code, _, let stderr, _) where code == 0:
          return
        case .exited(_, _, let stderrData, _):
          let stderrText = GitWorktreeShell.decodeUTF8(stderrData)
          let command = "git " + args.joined(separator: " ")
          let mapped = mapGitStderr(command: command, stderr: stderrText)
          // For uncommittedChanges, enrich with porcelain file list.
          if case .uncommittedChanges = mapped, !force {
            let porcelain = await GitWorktreeShell.run(
              executable: GitWorktreeShell.gitURL,
              arguments: [
                "-C", path.path(percentEncoded: false),
                "status", "--porcelain",
              ],
              cwd: path
            )
            if case .exited(_, let porcelainData, _, _) = porcelain {
              let files = parsePorcelainPaths(GitWorktreeShell.decodeUTF8(porcelainData))
              throw GitWorktreeError.uncommittedChanges(files: files)
            }
            throw GitWorktreeError.uncommittedChanges(files: [])
          }
          throw mapped
        case .timedOut:
          throw GitWorktreeError.commandFailed(
            command: "git " + args.joined(separator: " "), stderr: "timed out"
          )
        case .spawnFailed(let reason):
          throw GitWorktreeError.commandFailed(
            command: "git " + args.joined(separator: " "), stderr: reason
          )
        }
      },

      pruneWorktrees: { repoRoot in
        // Diff lsWorktrees before/after so the caller can surface an accurate
        // toast. `git worktree prune` itself prints nothing on success.
        let wt = try wtScriptURL()
        let before = await liveLsCount(wt: wt, repoRoot: repoRoot)
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "worktree", "prune",
          ],
          cwd: repoRoot
        )
        _ = try extractStdout(outcome, command: "git worktree prune")
        let after = await liveLsCount(wt: wt, repoRoot: repoRoot)
        return max(0, before - after)
      },

      fetchRemote: { repoRoot, remote in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "fetch", remote,
          ],
          cwd: repoRoot
        )
        switch outcome {
        case .exited(let code, _, let stderr, _) where code == 0:
          return
        case .exited(_, _, let stderrData, _):
          throw GitWorktreeError.fetchFailed(
            GitWorktreeShell.decodeUTF8(stderrData)
              .trimmingCharacters(in: .whitespacesAndNewlines)
          )
        case .timedOut:
          throw GitWorktreeError.fetchFailed("timed out")
        case .spawnFailed(let reason):
          throw GitWorktreeError.fetchFailed(reason)
        }
      },

      changedFiles: { worktreeRoot in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", worktreeRoot.path(percentEncoded: false),
            "status", "--porcelain",
          ],
          cwd: worktreeRoot
        )
        let stdout = try extractStdout(outcome, command: "git status --porcelain")
        return parsePorcelainPaths(stdout)
      }
    )
  }

  /// Helper for `pruneWorktrees` — best-effort count of non-bare entries
  /// from `wt ls --json`; returns 0 on any failure so the caller's diff
  /// degrades to reporting zero pruned instead of throwing.
  fileprivate static func liveLsCount(wt: URL, repoRoot: URL) async -> Int {
    let outcome = await GitWorktreeShell.run(
      executable: wt, arguments: ["ls", "--json"], cwd: repoRoot
    )
    guard case .exited(let code, let data, _, _) = outcome, code == 0 else { return 0 }
    let text = GitWorktreeShell.decodeUTF8(data).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
          let entries = try? JSONDecoder().decode([GitWtEntry].self, from: Data(text.utf8))
    else { return 0 }
    return entries.filter { !$0.isBare }.count
  }

  /// Unwraps a `CommandOutcome`'s successful stdout or throws a mapped
  /// `GitWorktreeError`. Used by the live closures for one-shot git
  /// calls that don't need specialized error handling.
  fileprivate static func extractStdout(_ outcome: CommandOutcome, command: String) throws -> String {
    switch outcome {
    case .exited(let code, let stdout, let stderr, _):
      guard code == 0 else {
        throw mapGitStderr(command: command, stderr: GitWorktreeShell.decodeUTF8(stderr))
      }
      return GitWorktreeShell.decodeUTF8(stdout)
    case .timedOut:
      throw GitWorktreeError.commandFailed(command: command, stderr: "timed out")
    case .spawnFailed(let reason):
      throw GitWorktreeError.commandFailed(command: command, stderr: reason)
    }
  }
}

// MARK: - DependencyKey

extension GitWorktreeClient: DependencyKey {
  /// Live value — bound to `makeLive()` which uses the bundled `wt`
  /// script and `/usr/bin/git`. Closures throw
  /// `GitWorktreeError.executableMissing` if the `wt` resource cannot
  /// be resolved (which the pre-build `verify-git-wt.sh` makes
  /// impossible in a clean build).
  static let liveValue: GitWorktreeClient = .makeLive()

  static let testValue: GitWorktreeClient = GitWorktreeClient(
    lsWorktrees: unimplemented("GitWorktreeClient.lsWorktrees", placeholder: []),
    localBranchNames: unimplemented("GitWorktreeClient.localBranchNames", placeholder: []),
    branchRefs: unimplemented("GitWorktreeClient.branchRefs", placeholder: []),
    defaultRemoteBranchRef: unimplemented("GitWorktreeClient.defaultRemoteBranchRef", placeholder: nil),
    isValidBranchName: unimplemented("GitWorktreeClient.isValidBranchName", placeholder: false),
    createWorktreeStream: { _ in
      AsyncThrowingStream { $0.finish() }
    },
    removeWorktree: unimplemented("GitWorktreeClient.removeWorktree"),
    pruneWorktrees: unimplemented("GitWorktreeClient.pruneWorktrees", placeholder: 0),
    fetchRemote: unimplemented("GitWorktreeClient.fetchRemote"),
    changedFiles: unimplemented("GitWorktreeClient.changedFiles", placeholder: [])
  )
}

extension DependencyValues {
  var gitWorktreeClient: GitWorktreeClient {
    get { self[GitWorktreeClient.self] }
    set { self[GitWorktreeClient.self] = newValue }
  }
}
