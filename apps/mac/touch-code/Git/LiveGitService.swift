import Foundation
import TouchCodeCore

/// Process-backed `GitService`. Invokes `git` with fixed argv (no shell), applies the env
/// whitelist from `GitProcessEnv`, caps output at 16 MiB, and enforces a 10 s wall-clock
/// timeout on every child.
///
/// `nonisolated` + `Sendable` (via `GitService`) — instances are immutable after init; every
/// operation constructs a fresh `Process` and returns a value. No stored mutable state.
final nonisolated class LiveGitService: GitService {
  static let maxOutputBytes = 16 * 1024 * 1024      // 16 MiB
  static let defaultTimeout: Duration = .seconds(10)

  private let gitExecutable: URL

  init(gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/env")) {
    self.gitExecutable = gitExecutable
  }

  // MARK: - GitService

  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage {
    // Request one extra row so we can set `hasMore` without a second invocation.
    let probeLimit = max(1, page.limit + 1)
    let argv = ["git"] + GitCommand.log(limit: probeLimit, skip: page.offset)
    let out = try await run(argv: argv, cwd: path)
    var commits = try GitOutputParser.parseLog(out)
    let hasMore = commits.count > page.limit
    if hasMore { commits.removeLast() }
    return LogPage(cursor: page, commits: commits, hasMore: hasMore)
  }

  func workingTreeDiff(at path: URL) async throws -> UnifiedDiff {
    let argv = ["git"] + GitCommand.diff(kind: .workingTree)
    let out = try await run(argv: argv, cwd: path)
    return try DiffParser.parse(out, scope: .working)
  }

  func stagedDiff(at path: URL) async throws -> UnifiedDiff {
    let argv = ["git"] + GitCommand.diff(kind: .staged)
    let out = try await run(argv: argv, cwd: path)
    return try DiffParser.parse(out, scope: .staged)
  }

  func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff {
    guard GitShaValidator.isValid(sha) else {
      throw GitError.invalidInput("not a git SHA: '\(sha)'")
    }
    let argv = ["git"] + GitCommand.diff(kind: .commit(sha: sha))
    let out = try await run(argv: argv, cwd: path)
    return try DiffParser.parse(out, scope: .commit(sha: sha))
  }

  func status(at path: URL) async throws -> WorkingTreeStatus {
    let argv = ["git"] + GitCommand.status()
    let out = try await run(argv: argv, cwd: path)
    return try GitOutputParser.parseStatus(out)
  }

  // MARK: - Process plumbing

  /// Spawns `gitExecutable` with `argv`, streams stdout + stderr into memory buffers capped at
  /// `maxOutputBytes`, and races the exit against a wall-clock timeout.
  private func run(argv: [String], cwd: URL) async throws -> Data {
    precondition(!argv.isEmpty, "run requires at least one arg")
    let process = Process()
    process.executableURL = gitExecutable
    process.arguments = argv
    process.currentDirectoryURL = cwd
    process.environment = GitProcessEnv.build()

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch let error as NSError {
      if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
        throw GitError.gitMissing
      }
      throw GitError.unparsable(context: "process spawn failed: \(error.localizedDescription)")
    }

    // Drain stdout + stderr into capped buffers concurrently with the wait.
    async let stdoutTask: (data: Data, overflow: Bool) = Self.drain(pipe: stdoutPipe)
    async let stderrTask: (data: Data, overflow: Bool) = Self.drain(pipe: stderrPipe)

    // Race timeout vs. process exit.
    let exitTask: Task<Int32, Never> = Task.detached {
      await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
        process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
      }
    }
    let timeoutTask = Task<Int32?, Never> {
      try? await Task.sleep(for: Self.defaultTimeout)
      return nil
    }

    var status: Int32 = 0
    var timedOut = false

    await withTaskGroup(of: ResultKind.self) { group in
      group.addTask { .exited(await exitTask.value) }
      group.addTask {
        _ = await timeoutTask.value
        return .timedOut
      }
      if let first = await group.next() {
        switch first {
        case .exited(let code):
          status = code
          timeoutTask.cancel()
        case .timedOut:
          timedOut = true
          process.terminate()
          // Give SIGTERM 1 s to land; if not, SIGKILL.
          try? await Task.sleep(for: .seconds(1))
          if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
          }
          status = await exitTask.value
        }
        group.cancelAll()
      }
    }

    let (stdoutData, stdoutOverflow) = await stdoutTask
    let (stderrData, _) = await stderrTask

    if timedOut { throw GitError.timedOut }
    if stdoutOverflow { throw GitError.outputTooLarge }
    if status != 0 {
      let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
      if stderrText.contains("not a git repository") {
        throw GitError.notARepo
      }
      throw GitError.exec(code: status, stderr: stderrText)
    }
    return stdoutData
  }

  private enum ResultKind: Sendable { case exited(Int32); case timedOut }

  /// Reads from a pipe until EOF or cap. Returns `overflow = true` if the cap was hit (buffer
  /// is truncated to the cap; further bytes discarded).
  private static func drain(pipe: Pipe) async -> (data: Data, overflow: Bool) {
    await Task.detached {
      var buffer = Data()
      buffer.reserveCapacity(64 * 1024)
      var overflow = false
      let handle = pipe.fileHandleForReading
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        if buffer.count + chunk.count > LiveGitService.maxOutputBytes {
          let remaining = LiveGitService.maxOutputBytes - buffer.count
          if remaining > 0 { buffer.append(chunk.prefix(remaining)) }
          overflow = true
          // Continue draining so the child doesn't block on a full pipe; discard extra bytes.
        } else {
          buffer.append(chunk)
        }
      }
      return (buffer, overflow)
    }.value
  }
}
