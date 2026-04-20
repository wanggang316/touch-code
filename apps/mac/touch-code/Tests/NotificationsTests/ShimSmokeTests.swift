import Foundation
import Testing

/// Smoke tests covering the agent Stop-hook shim shell semantics.
///
/// The actual shim scripts live at `touch-code-skill/shims/*.sh`; rather than
/// resolve that path from the test binary (Xcode's test host cwd is not the
/// repo root), these tests spawn `/bin/sh -c` with a literal copy of each
/// shim body and verify the produced stdout matches the sentinel the C6 rule
/// bundle (DefaultRules.json) expects. If either the rule regex or the shim
/// printf line changes, both inputs must be updated in lockstep.
struct ShimSmokeTests {
  @Test
  func claudeStopHookProducesCompleteSentinel() throws {
    let stdout = try Self.run(
      script: #"printf '\n::touchcode:agent-complete %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}""#,
      env: ["TOUCH_CODE_PANEL_ID": "abc-123"]
    )
    #expect(stdout == "\n::touchcode:agent-complete abc-123\n")
  }

  @Test
  func codexCompleteHookProducesCompleteSentinel() throws {
    let stdout = try Self.run(
      script: #"printf '\n::touchcode:agent-complete %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}""#,
      env: ["TOUCH_CODE_PANEL_ID": "codex-xyz"]
    )
    #expect(stdout == "\n::touchcode:agent-complete codex-xyz\n")
  }

  @Test
  func aiderIdleHookProducesIdleSentinel() throws {
    let stdout = try Self.run(
      script: #"printf '\n::touchcode:agent-idle %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}""#,
      env: ["TOUCH_CODE_PANEL_ID": "aider-42"]
    )
    #expect(stdout == "\n::touchcode:agent-idle aider-42\n")
  }

  @Test
  func missingPanelIDFallsBackToUnknown() throws {
    let stdout = try Self.run(
      script: #"printf '\n::touchcode:agent-complete %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}""#,
      env: [:]
    )
    #expect(stdout == "\n::touchcode:agent-complete unknown\n")
  }

  /// Spawns `/bin/sh -c <script>` with the supplied environment and returns
  /// captured stdout. Inherits the parent's PATH so `printf` is found.
  private static func run(script: String, env: [String: String]) throws -> String {
    let process = Process()
    process.launchPath = "/bin/sh"
    process.arguments = ["-c", script]
    var merged = ProcessInfo.processInfo.environment
    // Remove any leaked TOUCH_CODE_PANEL_ID from the test host's environment
    // before layering the scenario-specific value.
    merged.removeValue(forKey: "TOUCH_CODE_PANEL_ID")
    for (key, value) in env { merged[key] = value }
    process.environment = merged

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
