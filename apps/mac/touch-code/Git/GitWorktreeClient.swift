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
  ///
  /// All patterns are case-insensitive — git's message casing can vary
  /// with locale + version, and the `stderr.lowercased()` branches
  /// below matched case-insensitively long before the two regex
  /// branches did (issue #24 (b)). Inline `(?i)` keeps the original
  /// casing of the captured branch name so UI surfaces show what the
  /// user typed instead of a forced-lower version.
  static func mapGitStderr(command: String, stderr: String) -> GitWorktreeError {
    let lower = stderr.lowercased()
    if let match = stderr.firstMatch(of: /(?i)A branch named '([^']+)' already exists/) {
      return .branchExists(String(match.1))
    }
    if let match = stderr.firstMatch(of: /(?i)'([^']+)' is not a valid branch name/) {
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

  /// Identifies the created worktree path by diffing `wt ls --json`
  /// snapshots taken immediately before and after `wt sw`. Returns
  /// the single new entry's path; falls back to matching
  /// `fallbackStdoutLast` (the legacy last-line heuristic) when the
  /// diff is ambiguous, and nil when the diff is empty. Pure — all
  /// decisions flow from the arguments so the unit tests don't need a
  /// live git.
  ///
  /// Paths are compared via `URL.standardizedFileURL.path` so a
  /// trailing slash or `.` component difference between `wt sw`'s
  /// echo and `wt ls`'s canonicalized JSON doesn't produce a false
  /// mismatch. Issue #24 (c).
  static func pickNewWorktreePath(
    preEntries: [GitWtEntry],
    postEntries: [GitWtEntry],
    fallbackStdoutLast: String
  ) -> URL? {
    func canonical(_ path: String) -> String {
      URL(fileURLWithPath: path).standardizedFileURL.path
    }
    let prePaths = Set(preEntries.map { canonical($0.path) })
    let newEntries = postEntries.filter { !prePaths.contains(canonical($0.path)) }
    if newEntries.count == 1 {
      return URL(fileURLWithPath: newEntries[0].path).standardizedFileURL
    }
    if newEntries.isEmpty {
      // wt claimed success but ls still doesn't see a new entry —
      // caller will surface .commandFailed so the sheet reports
      // something rather than yielding a ghost path.
      return nil
    }
    // Multiple new entries — disambiguate via the legacy
    // last-non-empty-stdout heuristic. This is the belt-and-braces
    // path the plan calls out: if upstream `wt` ever prints a
    // reliable worktree path as its last stdout line, we still
    // honour it; if not, we fall through to the first entry and
    // let the caller log a warning.
    let fallbackTrimmed = fallbackStdoutLast.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallbackTrimmed.isEmpty {
      let fallbackCanonical = canonical(fallbackTrimmed)
      if let match = newEntries.first(where: { canonical($0.path) == fallbackCanonical }) {
        return URL(fileURLWithPath: match.path).standardizedFileURL
      }
    }
    return URL(fileURLWithPath: newEntries[0].path).standardizedFileURL
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

/// Thread-safe box holding the spawned `wt` Process so a cancellation
/// path on a different thread (`AsyncThrowingStream.onTermination`
/// is not isolated to any particular actor) can terminate it without
/// racing the Task body that assigned it. `@unchecked Sendable`
/// because the NSLock discipline is what actually enforces safety.
/// Issue #24 (a).
nonisolated final class CreateWorktreeProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?

  func set(_ p: Process) {
    lock.lock()
    process = p
    lock.unlock()
  }

  func terminateIfRunning() {
    lock.lock()
    let captured = process
    lock.unlock()
    guard let captured, captured.isRunning else { return }
    captured.terminate()
  }
}

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
  ///
  /// The optional `onSpawn` callback fires immediately before
  /// `process.run()` so the caller can capture the `Process` reference
  /// for external cancellation (see `createWorktreeStream`'s
  /// `continuation.onTermination` wiring — issue #24 (a)). Default
  /// is a no-op so existing callers stay source-compatible.
  static func runStream(
    executable: URL,
    arguments: [String],
    cwd: URL,
    onSpawn: @Sendable (Process) -> Void = { _ in },
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

      // Hand the Process to the caller before run() so a
      // cancellation path can hold a reference before the child
      // actually starts.
      onSpawn(process)

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
  // `onCreateWorktreeSpawn` is an optional testing seam — the live
  // `createWorktreeStream` path calls it with the spawned `wt`
  // Process immediately before `process.run()`. Production code
  // leaves it nil; integration tests pass a closure that captures a
  // weak reference to the Process so they can assert
  // `!process.isRunning` after cancelling the stream (issue #24 (a)).
  //
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func makeLive(
    onCreateWorktreeSpawn: (@Sendable (Process) -> Void)? = nil
  ) -> GitWorktreeClient {
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
          // Locked box so `continuation.onTermination` (fires on any
          // thread / isolation context) can safely read the Process
          // reference and terminate the child. Without this, a
          // cancelled consumer leaks the `wt` child until it finishes
          // on its own — see issue #24 (a).
          let processBox = CreateWorktreeProcessBox()

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

              // Snapshot the live worktree set BEFORE spawning `wt sw`.
              // After exit we diff against this to identify the new
              // entry — more robust than treating wt's last-non-empty
              // stdout line as the path (issue #24 (c)). Best-effort:
              // if wt ls fails for any reason, we fall through with an
              // empty snapshot and the diff will surface every
              // post-create entry; the fallbackStdoutLast path then
              // picks the right one.
              let preEntries = await liveLsEntries(wt: wt, repoRoot: spec.repoRoot)

              let args = makeCreateArguments(for: spec)
              let outcome = await GitWorktreeShell.runStream(
                executable: wt,
                arguments: args,
                cwd: spec.repoRoot,
                onSpawn: { process in
                  processBox.set(process)
                  onCreateWorktreeSpawn?(process)
                },
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

              // Post-snapshot + diff. We don't require stdoutLast to
              // be non-empty anymore — it's a tiebreaker, not the
              // primary source.
              let postEntries = await liveLsEntries(wt: wt, repoRoot: spec.repoRoot)
              guard let worktreeURL = pickNewWorktreePath(
                preEntries: preEntries,
                postEntries: postEntries,
                fallbackStdoutLast: outcome.stdoutLast
              ) else {
                continuation.finish(throwing: GitWorktreeError.commandFailed(
                  command: "wt \(args.joined(separator: " "))",
                  stderr: "wt exited 0 but no new worktree appeared in wt ls"
                ))
                return
              }
              continuation.yield(.finished(worktreePath: worktreeURL))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
          continuation.onTermination = { _ in
            // Order matters: terminate the child FIRST so
            // `runStream`'s terminationHandler fires and resumes its
            // continuation naturally (Task body completes, reaches
            // the final `continuation.finish(...)`). Cancelling the
            // Task first would still leave the wt child alive until
            // it finished, defeating the point of this handler.
            // Issue #24 (a).
            processBox.terminateIfRunning()
            task.cancel()
          }
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

  /// Best-effort `wt ls --json` → `[GitWtEntry]`. Returns `[]` on any
  /// failure — used by `createWorktreeStream` for the diff-based
  /// path-picking (issue #24 (c)) and by `pruneWorktrees` for its
  /// before/after count. Both callers tolerate empty on error.
  fileprivate static func liveLsEntries(wt: URL, repoRoot: URL) async -> [GitWtEntry] {
    let outcome = await GitWorktreeShell.run(
      executable: wt, arguments: ["ls", "--json"], cwd: repoRoot
    )
    guard case .exited(let code, let data, _, _) = outcome, code == 0 else { return [] }
    let text = GitWorktreeShell.decodeUTF8(data).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
          let entries = try? JSONDecoder().decode([GitWtEntry].self, from: Data(text.utf8))
    else { return [] }
    return entries.filter { !$0.isBare }
  }

  /// Helper for `pruneWorktrees` — best-effort count of non-bare entries
  /// from `wt ls --json`; returns 0 on any failure so the caller's diff
  /// degrades to reporting zero pruned instead of throwing.
  fileprivate static func liveLsCount(wt: URL, repoRoot: URL) async -> Int {
    await liveLsEntries(wt: wt, repoRoot: repoRoot).count
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
