import Foundation
import Testing

@testable import TouchCodeCore

struct HookEventDataCodableTests {
  @Test
  func paneCreatedRoundTrip() throws {
    try roundTrip(.paneCreated(createdVia: "cli"))
  }

  @Test
  func paneReadyRoundTrip() throws {
    try roundTrip(.paneReady(pid: 4242, shell: "/bin/zsh"))
    try roundTrip(.paneReady(pid: nil, shell: "/bin/bash"))
  }

  @Test
  func paneInputRoundTrip() throws {
    try roundTrip(.paneInput(text: "ls\n", inputBytes: 3))
  }

  @Test
  func paneOutputRoundTrip() throws {
    let data = Data("hello".utf8)
    try roundTrip(.paneOutput(output: data, outputBytes: data.count))
  }

  @Test
  func paneOutputMatchRoundTrip() throws {
    let data = Data("READY FOR REVIEW".utf8)
    try roundTrip(.paneOutputMatch(
      match: "READY", matchedRange: HookMatchRange(start: 0, length: 5),
      output: data, outputBytes: data.count
    ))
  }

  @Test
  func paneIdleRoundTrip() throws {
    try roundTrip(.paneIdle(idleSeconds: 60, sinceLastOutput: 62, sinceLastInput: 80))
  }

  @Test
  func paneExitedAndCrashedRoundTrip() throws {
    try roundTrip(.paneExited(exitCode: 0))
    try roundTrip(.paneExited(exitCode: 137))
    try roundTrip(.paneCrashed(reason: "surface faulted: EXC_BAD_ACCESS"))
  }

  @Test
  func tabEventsRoundTrip() throws {
    try roundTrip(.tabActivated(previousTabID: TabID()))
    try roundTrip(.tabActivated(previousTabID: nil))
    try roundTrip(.tabDeactivated(nextTabID: TabID()))
    try roundTrip(.tabAutoClosed(reason: "3 crashes in 30s", crashCount: 3, windowSeconds: 30))
  }

  @Test
  func worktreeEventsRoundTrip() throws {
    try roundTrip(.worktreeActivated(previousWorktreeID: WorktreeID()))
    try roundTrip(.worktreeDeactivated(nextWorktreeID: nil))
    try roundTrip(.worktreeCreated(branch: "exp/validate", gitExit: 0))
    try roundTrip(.worktreeCreated(branch: nil, gitExit: nil))
    try roundTrip(.worktreeRemoved(keepDirectory: false))
  }

  @Test
  func discriminatorTagsMatchEvent() throws {
    let payload = HookEventData.paneReady(pid: 1, shell: "/bin/sh")
    let data = try JSONEncoder().encode(payload)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"kind\":\"pane.ready\""))
  }

  @Test
  func decodeRejectsUnknownKind() throws {
    let bad = Data(#"{"kind":"pane.reticulate","shell":"/bin/sh"}"#.utf8)
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(HookEventData.self, from: bad)
    }
  }

  private func roundTrip(_ value: HookEventData) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(HookEventData.self, from: data)
    #expect(decoded == value)
  }
}
