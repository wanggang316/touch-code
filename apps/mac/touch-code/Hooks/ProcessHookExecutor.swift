import Darwin
import Foundation
import os
import TouchCodeCore

/// Production `HookExecutor` — spawns a user shell handler per matched
/// subscription. The handler reads the JSON `HookEnvelope` on stdin and
/// may emit zero or more `HookAction`s on stdout (one per line or a
/// single JSON array).
///
/// Design decisions:
/// - **`/bin/sh -c <command>`**: argv-array shape so the command is
///   never re-interpolated through an outer shell. `command` itself is a
///   shell command string (that's its contract), but nothing *around* it
///   can inject extra argv.
/// - **Env allowlist**: we wipe the inherited environment to a tight
///   allowlist (`PATH`, `HOME`, `USER`, `SHELL`, `LANG`, `LC_ALL`,
///   `TERM`), then merge in `subscription.env`. Subscription-supplied
///   keys can override the allowlist — that's intentional, users need
///   to be able to pin a particular `$PATH` — but nothing from the
///   host app's env leaks by default.
/// - **Timeout**: `subscription.timeoutSeconds`, enforced via a
///   cancellable `Task.sleep` + `SIGTERM`. Timed-out handlers
///   surface `timedOut = true` and `exitCode = SIGTERM + 128`.
/// - **stdout parse**: if the output is valid JSON (array or single
///   object), decode as `[HookAction]`. Anything else is ignored — log
///   and move on. Hooks that don't emit actions simply return empty
///   stdout.
/// - **`fireAndForget` vs `awaitActions`**: `fireAndForget` backgrounds
///   the handler and returns `.zero` immediately (the dispatcher gets
///   no stdout). `awaitActions` waits and returns parsed actions. The
///   default subscription mode is `fireAndForget`.
public final class ProcessHookExecutor: HookExecutor, @unchecked Sendable {
  public enum SpawnError: Error, Equatable {
    case launchFailed(underlying: String)
  }

  private let logger = Logger(subsystem: "com.touch-code.hooks", category: "exec")
  private let shellPath: String
  private let semaphore: AsyncSemaphore?

  public init(shellPath: String = "/bin/sh", semaphore: AsyncSemaphore? = nil) {
    self.shellPath = shellPath
    self.semaphore = semaphore
  }

  public func run(
    subscription: HookSubscription,
    envelope: HookEnvelope
  ) async -> HookExecutionResult {
    if subscription.mode == .fireAndForget {
      // Spawn + don't await; the detached Task owns the handler. The
      // dispatcher records a zero-outcome HookFireRecord immediately.
      // The dispatcher's own permit only spans scheduling (this call
      // returns .zero immediately), so re-acquire the shared permit
      // inside the detached task to bound the real `/bin/sh` spawn.
      let semaphore = self.semaphore
      Task.detached { [weak self] in
        await semaphore?.acquire()
        _ = await self?.runBlocking(subscription: subscription, envelope: envelope)
        await semaphore?.release()
      }
      return .zero
    }
    return await runBlocking(subscription: subscription, envelope: envelope)
  }

  // MARK: - Core spawn

  private func runBlocking(
    subscription: HookSubscription,
    envelope: HookEnvelope
  ) async -> HookExecutionResult {
    let start = Date()
    let encoded: Data
    do {
      encoded = try HookEnvelope.encoder().encode(envelope)
    } catch {
      logger.error("envelope encode failed: \(String(describing: error), privacy: .public)")
      return HookExecutionResult(exitCode: -1, duration: Date().timeIntervalSince(start))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    process.arguments = ["-c", subscription.command]
    process.environment = Self.buildEnvironment(subscription: subscription)
    if let cwd = subscription.cwd, !cwd.isEmpty {
      process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    }

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Async accumulators — `readToEnd()` can block forever if an
    // orphaned grandchild (e.g. a `sh` that spawned a `sleep` and got
    // SIGKILLed) still holds the write side open. Reading via
    // `readabilityHandler` drains whatever the direct child wrote and
    // lets us bail out after the timeout ladder without waiting for a
    // grandchild-held fd to close.
    let stdoutAccumulator = PipeAccumulator(handle: stdoutPipe.fileHandleForReading)
    let stderrAccumulator = PipeAccumulator(handle: stderrPipe.fileHandleForReading)

    do {
      try process.run()
    } catch {
      logger.error("spawn failed: \(String(describing: error), privacy: .public)")
      stdoutAccumulator.stop()
      stderrAccumulator.stop()
      return HookExecutionResult(
        exitCode: -1,
        stderr: Data("spawn failed: \(error)\n".utf8),
        duration: Date().timeIntervalSince(start)
      )
    }

    // Feed stdin (best-effort; ignore broken-pipe if the handler closes
    // before reading).
    do {
      try stdinPipe.fileHandleForWriting.write(contentsOf: encoded)
      try stdinPipe.fileHandleForWriting.close()
    } catch {
      logger.debug("stdin write failed (handler may have closed): \(String(describing: error), privacy: .public)")
      try? stdinPipe.fileHandleForWriting.close()
    }

    // Wait for exit with timeout + SIGTERM→SIGKILL escalation ladder.
    // After the deadline: SIGTERM, 1 s grace, then SIGKILL if the handler
    // trapped SIGTERM or is otherwise still resident. Post-return the
    // process is guaranteed reaped (no FD leak even on misbehaving
    // handlers).
    let timeoutSeconds = max(0.1, subscription.timeoutSeconds)
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    let timedOut = await Self.waitWithTimeout(process: process, deadline: deadline)

    stdoutAccumulator.stop()
    stderrAccumulator.stop()
    let stdoutData = stdoutAccumulator.data
    let stderrData = stderrAccumulator.data
    let actions = Self.parseActions(stdoutData)
    // waitWithTimeout guarantees the process is reaped before returning,
    // so terminationStatus is stable here. On timeout the status reflects
    // whatever signal killed it (SIGTERM exits 143; SIGKILL exits 137
    // after the escalation ladder); waitWithTimeout synthesises the
    // POSIX 128+signal convention when the Foundation bridging collapses
    // signal exits to raw status codes.
    let exitCode = process.terminationStatus

    return HookExecutionResult(
      exitCode: exitCode,
      stdout: stdoutData,
      stderr: stderrData,
      duration: Date().timeIntervalSince(start),
      timedOut: timedOut,
      actions: actions
    )
  }

  /// Wait for the process to exit or force-terminate at `deadline`.
  /// Returns `true` iff the deadline expired first. By the time this
  /// returns the process has either exited naturally or been reaped
  /// through the SIGTERM → (1 s grace) → SIGKILL ladder.
  private static func waitWithTimeout(
    process: Process,
    deadline: Date
  ) async -> Bool {
    // Phase 1 — race natural exit against the deadline.
    //
    // Single-shot `WaitState<Bool>`: resolved with `false` if the
    // process exits first (via `terminationHandler`), or with `true` if
    // the deadline timer fires first. Second/later `resolve` calls are
    // no-ops, so the slower path is safe to fire.
    let phase1 = WaitState<Bool>()
    process.terminationHandler = { _ in phase1.resolve(false) }
    let timer = Task.detached {
      let interval = deadline.timeIntervalSinceNow
      if interval > 0 {
        try? await Task.sleep(for: .seconds(interval))
      }
      phase1.resolve(true)
    }
    let timedOut = await phase1.wait()
    timer.cancel()

    if !timedOut {
      // Natural exit — `terminationStatus` is stable.
      return false
    }

    // Phase 2 — escalation ladder. SIGTERM, poll up to 1 s for the
    // process to collapse, then SIGKILL if it's still resident. Polling
    // rather than re-arming a second `WaitState` is deliberate: the
    // termination handler has already been consumed by phase 1 and the
    // grace window is a non-hot path (runs only on genuine runaways).
    process.terminate() // SIGTERM
    let graceDeadline = Date(timeIntervalSinceNow: 1.0)
    while process.isRunning, Date() < graceDeadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      let killDeadline = Date(timeIntervalSinceNow: 2.0)
      while process.isRunning, Date() < killDeadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    return true
  }

  /// Single-shot awaitable. Resolves all waiters on the first `resolve`;
  /// later resolves are idempotent. Thread-safe. Nonisolated so the
  /// subprocess `terminationHandler` (called from a background thread)
  /// can complete the wait.
  nonisolated private final class WaitState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    nonisolated func resolve(_ value: T) {
      lock.lock()
      if resolved != nil {
        lock.unlock()
        return
      }
      resolved = value
      let pending = waiters
      waiters.removeAll()
      lock.unlock()
      for waiter in pending {
        waiter.resume(returning: value)
      }
    }

    nonisolated func wait() async -> T {
      await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        lock.lock()
        if let value = resolved {
          lock.unlock()
          continuation.resume(returning: value)
          return
        }
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  /// Async drain of a pipe's read side via `readabilityHandler`. The
  /// subprocess writes; this accumulates into a locked buffer off the
  /// main thread. `stop()` detaches the handler and is safe to call
  /// twice. The final `data` snapshot reflects everything the direct
  /// child process wrote before the handler was detached — a later
  /// orphan grandchild can keep writing but those bytes are dropped
  /// (intentional; we don't want to block the dispatcher on a runaway
  /// grandchild).
  nonisolated private final class PipeAccumulator: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false

    init(handle: FileHandle) {
      self.handle = handle
      handle.readabilityHandler = { [weak self] fileHandle in
        guard let self else { return }
        let chunk = fileHandle.availableData
        if chunk.isEmpty {
          // Peer closed; Foundation signals EOF via empty read.
          self.stop()
          return
        }
        self.lock.lock()
        if !self.stopped {
          self.buffer.append(chunk)
        }
        self.lock.unlock()
      }
    }

    var data: Data {
      lock.lock(); defer { lock.unlock() }
      return buffer
    }

    func stop() {
      lock.lock()
      let wasStopped = stopped
      stopped = true
      lock.unlock()
      guard !wasStopped else { return }
      handle.readabilityHandler = nil
      try? handle.close()
    }
  }

  // MARK: - Environment allowlist

  /// Keys that pass through from the host process environment by
  /// default. Anything else is dropped unless the subscription's `env`
  /// overrides it explicitly.
  static let inheritedKeys: Set<String> = [
    "PATH", "HOME", "USER", "SHELL", "LANG", "LC_ALL", "TERM",
  ]

  static func buildEnvironment(subscription: HookSubscription) -> [String: String] {
    var env: [String: String] = [:]
    let host = ProcessInfo.processInfo.environment
    for key in inheritedKeys {
      if let value = host[key] { env[key] = value }
    }
    for (key, value) in subscription.env {
      env[key] = value
    }
    return env
  }

  // MARK: - Stdout parsing

  /// Parse handler stdout as either a JSON array of `HookAction` or a
  /// newline-separated list of JSON objects. Invalid input returns an
  /// empty array (logged at debug level).
  static func parseActions(_ data: Data) -> [HookAction] {
    guard !data.isEmpty else { return [] }
    let decoder = JSONDecoder()
    if let actions = try? decoder.decode([HookAction].self, from: data) {
      return actions
    }
    // Newline-separated NDJSON fallback.
    var out: [HookAction] = []
    if let text = String(data: data, encoding: .utf8) {
      for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        if let action = try? decoder.decode(HookAction.self, from: Data(trimmed.utf8)) {
          out.append(action)
        }
      }
    }
    return out
  }
}
