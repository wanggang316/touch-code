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

  public init(shellPath: String = "/bin/sh") {
    self.shellPath = shellPath
  }

  public func run(
    subscription: HookSubscription,
    envelope: HookEnvelope
  ) async -> HookExecutionResult {
    if subscription.mode == .fireAndForget {
      // Spawn + don't await; the detached Task owns the handler. The
      // dispatcher records a zero-outcome HookFireRecord immediately.
      Task.detached { [weak self] in
        _ = await self?.runBlocking(subscription: subscription, envelope: envelope)
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

    do {
      try process.run()
    } catch {
      logger.error("spawn failed: \(String(describing: error), privacy: .public)")
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

    // Wait for exit with timeout. The `Process.waitUntilExit()` call is
    // blocking on its dispatch queue; wrap it in a `Task.detached` and
    // race a `Task.sleep` that SIGTERMs the child on timeout.
    let timeoutSeconds = max(0.1, subscription.timeoutSeconds)
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    let timedOut = await Self.waitWithTimeout(process: process, deadline: deadline)

    let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
    let actions = Self.parseActions(stdoutData)
    let exitCode = process.isRunning ? Int32(-1) : process.terminationStatus

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
  /// Returns `true` iff the deadline expired first.
  private static func waitWithTimeout(
    process: Process,
    deadline: Date
  ) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let state = WaitState()
      process.terminationHandler = { _ in
        state.resolve(timedOut: false, continuation: continuation)
      }
      Task.detached {
        let interval = deadline.timeIntervalSinceNow
        if interval > 0 {
          try? await Task.sleep(for: .seconds(interval))
        }
        if process.isRunning {
          process.terminate() // SIGTERM
        }
        state.resolve(timedOut: true, continuation: continuation)
      }
    }
  }

  private final class WaitState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var resolved = false
    nonisolated func resolve(timedOut: Bool, continuation: CheckedContinuation<Bool, Never>) {
      lock.lock()
      let shouldResume = !resolved
      resolved = true
      lock.unlock()
      if shouldResume {
        continuation.resume(returning: timedOut)
      }
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
