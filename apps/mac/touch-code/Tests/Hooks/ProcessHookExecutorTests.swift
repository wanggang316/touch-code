import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore
@testable import TouchCodeIPC

@MainActor
struct ProcessHookExecutorTests {
  @Test
  func envAllowlistStripsHostSecrets() {
    setenv("TOUCH_CODE_SECRET_TEST", "leaked", 1)
    defer { unsetenv("TOUCH_CODE_SECRET_TEST") }
    let sub = HookSubscription(event: .panelReady, command: "echo")
    let env = ProcessHookExecutor.buildEnvironment(subscription: sub)
    #expect(env["TOUCH_CODE_SECRET_TEST"] == nil)
    // PATH / HOME are allowlisted and usually present on macOS.
    #expect(env["PATH"] != nil || ProcessInfo.processInfo.environment["PATH"] == nil)
  }

  @Test
  func subscriptionEnvOverridesAllowlist() {
    let sub = HookSubscription(
      event: .panelReady,
      command: "echo",
      env: ["PATH": "/my/custom/path", "MY_FLAG": "1"]
    )
    let env = ProcessHookExecutor.buildEnvironment(subscription: sub)
    #expect(env["PATH"] == "/my/custom/path")
    #expect(env["MY_FLAG"] == "1")
  }

  @Test
  func parseActionsDecodesJSONArray() throws {
    let action = HookAction.notify(title: "hi", body: nil, panelID: nil)
    let encoded = try JSONEncoder().encode([action])
    let parsed = ProcessHookExecutor.parseActions(encoded)
    #expect(parsed.count == 1)
    if case .notify(let title, _, _) = parsed[0] {
      #expect(title == "hi")
    } else {
      Issue.record("expected .notify")
    }
  }

  @Test
  func parseActionsDecodesNDJSON() throws {
    let a1 = HookAction.log(level: "info", message: "one")
    let a2 = HookAction.log(level: "info", message: "two")
    let encoder = JSONEncoder()
    var bytes = Data()
    bytes.append(try encoder.encode(a1))
    bytes.append(Data("\n".utf8))
    bytes.append(try encoder.encode(a2))
    let parsed = ProcessHookExecutor.parseActions(bytes)
    #expect(parsed.count == 2)
  }

  @Test
  func parseActionsReturnsEmptyOnGarbage() {
    let parsed = ProcessHookExecutor.parseActions(Data("not json at all".utf8))
    #expect(parsed.isEmpty)
  }

  @Test
  func awaitActionsModeRunsShellAndReturnsExitCode() async throws {
    let executor = ProcessHookExecutor()
    let sub = HookSubscription(
      event: .panelReady,
      command: "exit 7",
      timeoutSeconds: 5,
      mode: .awaitActions
    )
    let envelope = Self.makePanelReadyEnvelope()
    let result = await executor.run(subscription: sub, envelope: envelope)
    #expect(result.exitCode == 7)
    #expect(result.timedOut == false)
    #expect(result.actions.isEmpty)
  }

  @Test
  func awaitActionsModeCapturesStdoutJSON() async throws {
    let executor = ProcessHookExecutor()
    let sub = HookSubscription(
      event: .panelReady,
      command: #"echo '[{"kind":"log","level":"info","message":"from-handler"}]'"#,
      timeoutSeconds: 5,
      mode: .awaitActions
    )
    let envelope = Self.makePanelReadyEnvelope()
    let result = await executor.run(subscription: sub, envelope: envelope)
    #expect(result.exitCode == 0)
    #expect(result.actions.count == 1)
    if case .log(let level, let message) = result.actions.first {
      #expect(level == "info")
      #expect(message == "from-handler")
    } else {
      Issue.record("expected .log action")
    }
  }

  @Test
  func awaitActionsModeHonorsTimeout() async throws {
    let executor = ProcessHookExecutor()
    let sub = HookSubscription(
      event: .panelReady,
      command: "sleep 30",
      timeoutSeconds: 0.3,
      mode: .awaitActions
    )
    let envelope = Self.makePanelReadyEnvelope()
    let start = Date()
    let result = await executor.run(subscription: sub, envelope: envelope)
    let elapsed = Date().timeIntervalSince(start)
    #expect(result.timedOut == true)
    #expect(elapsed < 2.0, "timeout took \(elapsed)s — should have killed at ~0.3s")
    // Foundation reports signalled exits as the raw signal number on
    // macOS. SIGTERM=15, SIGKILL=9. Either is acceptable proof of a
    // killed-by-signal exit as opposed to a clean 0 or a -1 "never
    // updated" race.
    #expect(result.exitCode != 0, "timed-out handler must not report clean exit (got \(result.exitCode))")
    #expect(result.exitCode != -1, "timed-out handler must report a real signal exit (got -1 suggests isRunning race)")
  }

  @Test
  func sigtermTrappingHandlerGetsEscalatedToSIGKILL() async throws {
    let executor = ProcessHookExecutor()
    // A handler that traps SIGTERM and keeps sleeping. With only
    // SIGTERM the executor would leak the fd until the process exits
    // naturally (30 s). The ladder must SIGKILL it within ~1 s grace.
    let sub = HookSubscription(
      event: .panelReady,
      command: "trap '' TERM; sleep 30",
      timeoutSeconds: 0.3,
      mode: .awaitActions
    )
    let envelope = Self.makePanelReadyEnvelope()
    let start = Date()
    let result = await executor.run(subscription: sub, envelope: envelope)
    let elapsed = Date().timeIntervalSince(start)
    #expect(result.timedOut == true)
    #expect(elapsed < 3.0, "SIGKILL ladder must reap trap-TERM within ~1.3s; took \(elapsed)s")
    #expect(result.exitCode != 0)
  }

  @Test
  func fireAndForgetReturnsZeroImmediately() async throws {
    let executor = ProcessHookExecutor()
    let sub = HookSubscription(
      event: .panelReady,
      command: "sleep 30", // would block for 30s if awaited
      timeoutSeconds: 60,
      mode: .fireAndForget
    )
    let envelope = Self.makePanelReadyEnvelope()
    let start = Date()
    let result = await executor.run(subscription: sub, envelope: envelope)
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 1.0, "fireAndForget should return fast; took \(elapsed)s")
    #expect(result.exitCode == 0)
  }

  // MARK: - Helpers

  static func makePanelReadyEnvelope() -> HookEnvelope {
    HookEnvelope(
      event: .panelReady,
      data: .panelReady(pid: nil, shell: "bash")
    )
  }
}
