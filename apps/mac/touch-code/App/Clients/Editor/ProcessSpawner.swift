import Foundation

/// The single `Foundation.Process` seam. `EditorService+Live` funnels every spawn through
/// `spawnForOpen`, so tests can inject a `RecordingProcessSpawner` and assert on argv/env/cwd
/// without ever starting a real editor.
nonisolated protocol ProcessSpawner: Sendable {
  func spawnForOpen(
    argv: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration
  ) async -> ProcessOutcome
}

/// The outcome of one spawn attempt. Maps 1:1 to branches in `EditorError`.
nonisolated enum ProcessOutcome: Equatable, Sendable {
  case exited(code: Int32, stderr: String)
  case timedOut
  case spawnFailed(reason: String)
}

/// Live spawner: real `Foundation.Process` with the 5 s → SIGTERM → 1 s → SIGKILL contract.
///
/// Correctness pattern mirrors `FoundationCommandRunner` (0005 M2 review fixes):
/// - `terminationHandler` is installed synchronously before `process.run()`. No
///   `Task.detached { withCheckedContinuation { … } }` race window.
/// - Pipe drains run on `DispatchQueue.global(qos: .utility)`, not the cooperative pool.
nonisolated struct FoundationProcessSpawner: ProcessSpawner {
  func spawnForOpen(
    argv: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration
  ) async -> ProcessOutcome {
    precondition(!argv.isEmpty, "argv must contain at least the binary path")
    let binaryPath = argv[0]
    let binaryURL = URL(fileURLWithPath: binaryPath)

    let process = Process()
    process.executableURL = binaryURL
    process.arguments = Array(argv.dropFirst())
    process.currentDirectoryURL = cwd
    process.environment = env
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Install exit continuation BEFORE run().
    let (exitStream, exitCont) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { p in
      exitCont.yield(p.terminationStatus)
      exitCont.finish()
    }

    // Drain pipes on a background queue (blocking reads; off the cooperative pool).
    async let stdoutData: Data = Self.drain(pipe: stdoutPipe)
    async let stderrData: Data = Self.drain(pipe: stderrPipe)

    do {
      try process.run()
    } catch let error as NSError {
      exitCont.finish()
      // Explicitly close the write ends so the drain coroutines see EOF and return.
      // Foundation would close them on Pipe.deinit, but that's a fragile implicit EOF:
      // if the pipes escape into the task-group's capture list lifetime (they do), the
      // await on stdoutData/stderrData can block until ARC collects them. Closing here
      // guarantees the drains complete before we return.
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      _ = await stdoutData
      _ = await stderrData
      if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
        return .spawnFailed(reason: "binary not found: \(binaryPath)")
      }
      return .spawnFailed(reason: error.localizedDescription)
    }

    // Race exit vs. timeout.
    let exit = await awaitExitOrTimeout(exitStream: exitStream, process: process, timeout: timeout)
    _ = await stdoutData  // drain for cleanliness
    let stderr = await stderrData

    switch exit {
    case .exited(let code):
      let stderrText = String(data: stderr, encoding: .utf8) ?? ""
      return .exited(code: code, stderr: stderrText)
    case .timedOut:
      return .timedOut
    }
  }

  private enum ExitOrTimeout: Sendable {
    case exited(Int32)
    case timedOut
  }

  private func awaitExitOrTimeout(
    exitStream: AsyncStream<Int32>,
    process: Process,
    timeout: Duration
  ) async -> ExitOrTimeout {
    await withTaskGroup(of: ExitOrTimeout.self) { group in
      group.addTask {
        for await code in exitStream { return .exited(code) }
        return .exited(Int32(-1))
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return .timedOut
      }
      defer { group.cancelAll() }
      guard let first = await group.next() else { return .exited(Int32(-1)) }
      switch first {
      case .exited(let code):
        return .exited(code)
      case .timedOut:
        process.terminate()
        try? await Task.sleep(for: SpawnContract.sigtermGrace)
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
        }
        return .timedOut
      }
    }
  }

  /// Drains a pipe to EOF on a dedicated background queue. Past `maxCapturedBytes`, further
  /// bytes are discarded but the loop continues so the child never blocks on a full pipe.
  private static func drain(pipe: Pipe) async -> Data {
    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
      DispatchQueue.global(qos: .utility).async {
        var buffer = Data()
        buffer.reserveCapacity(1024)
        let handle = pipe.fileHandleForReading
        while true {
          let chunk = handle.availableData
          if chunk.isEmpty { break }
          if buffer.count + chunk.count > SpawnContract.maxCapturedBytes {
            let remaining = SpawnContract.maxCapturedBytes - buffer.count
            if remaining > 0 { buffer.append(chunk.prefix(remaining)) }
            // Drain-past-cap contract: keep reading to EOF, discard excess.
          } else {
            buffer.append(chunk)
          }
        }
        cont.resume(returning: buffer)
      }
    }
  }
}

/// Test double. Tests supply a canned `ProcessOutcome` and the spawner records every call so
/// assertions can verify argv, env, cwd, and timeout without a real child. Actor semantics
/// give us safe concurrent access without reaching for `NSLock` in Swift 6.
actor RecordingProcessSpawner: ProcessSpawner {
  struct Recorded: Equatable, Sendable {
    var argv: [String]
    var env: [String: String]
    var cwd: URL
    var timeout: Duration
  }

  private var _calls: [Recorded] = []
  private var _outcomes: [ProcessOutcome] = [.exited(code: 0, stderr: "")]

  var calls: [Recorded] { _calls }

  func setOutcomes(_ outcomes: [ProcessOutcome]) {
    _outcomes = outcomes.isEmpty ? [.exited(code: 0, stderr: "")] : outcomes
  }

  nonisolated func spawnForOpen(
    argv: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration
  ) async -> ProcessOutcome {
    await self.record(argv: argv, env: env, cwd: cwd, timeout: timeout)
  }

  private func record(
    argv: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration
  ) -> ProcessOutcome {
    _calls.append(Recorded(argv: argv, env: env, cwd: cwd, timeout: timeout))
    let outcome = _outcomes.first ?? .exited(code: 0, stderr: "")
    if _outcomes.count > 1 { _outcomes.removeFirst() }
    return outcome
  }
}
