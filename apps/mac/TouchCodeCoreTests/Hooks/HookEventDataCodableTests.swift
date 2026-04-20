import Foundation
import Testing

@testable import TouchCodeCore

struct HookEventDataCodableTests {
  @Test
  func panelCreatedRoundTrip() throws {
    try roundTrip(.panelCreated(createdVia: "cli"))
  }

  @Test
  func panelReadyRoundTrip() throws {
    try roundTrip(.panelReady(pid: 4242, shell: "/bin/zsh"))
    try roundTrip(.panelReady(pid: nil, shell: "/bin/bash"))
  }

  @Test
  func panelInputRoundTrip() throws {
    try roundTrip(.panelInput(text: "ls\n", inputBytes: 3))
  }

  @Test
  func panelOutputRoundTrip() throws {
    let data = Data("hello".utf8)
    try roundTrip(.panelOutput(output: data, outputBytes: data.count))
  }

  @Test
  func panelOutputMatchRoundTrip() throws {
    let data = Data("READY FOR REVIEW".utf8)
    try roundTrip(.panelOutputMatch(
      match: "READY", matchedRange: HookMatchRange(start: 0, length: 5),
      output: data, outputBytes: data.count
    ))
  }

  @Test
  func panelIdleRoundTrip() throws {
    try roundTrip(.panelIdle(idleSeconds: 60, sinceLastOutput: 62, sinceLastInput: 80))
  }

  @Test
  func panelExitedAndCrashedRoundTrip() throws {
    try roundTrip(.panelExited(exitCode: 0))
    try roundTrip(.panelExited(exitCode: 137))
    try roundTrip(.panelCrashed(reason: "surface faulted: EXC_BAD_ACCESS"))
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
    let payload = HookEventData.panelReady(pid: 1, shell: "/bin/sh")
    let data = try JSONEncoder().encode(payload)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"kind\":\"panel.ready\""))
  }

  @Test
  func decodeRejectsUnknownKind() throws {
    let bad = Data(#"{"kind":"panel.reticulate","shell":"/bin/sh"}"#.utf8)
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
