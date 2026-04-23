import Foundation
import Testing

@testable import TouchCodeCore

struct HookEnvelopeCodableTests {
  @Test
  func paneScopedEnvelopeRoundTrips() throws {
    let env = Self.fullPaneEnvelope()
    let data = try JSONEncoder().encode(env)
    let decoded = try JSONDecoder().decode(HookEnvelope.self, from: data)
    #expect(decoded == env)
  }

  @Test
  func worktreeScopedEnvelopeRoundTrips() throws {
    let env = HookEnvelope(
      event: .worktreeCreated,
      timestamp: Date(timeIntervalSince1970: 1700000000),
      space: .init(id: SpaceID(), name: "work"),
      project: .init(id: ProjectID(), name: "touch-code", rootPath: "/repo"),
      worktree: .init(id: WorktreeID(), name: "exp", path: "/wt", branch: "exp"),
      data: .worktreeCreated(branch: "exp", gitExit: 0)
    )
    let data = try JSONEncoder().encode(env)
    let decoded = try JSONDecoder().decode(HookEnvelope.self, from: data)
    #expect(decoded == env)
  }

  @Test
  func validateAnchorsAcceptsFullPaneEnvelope() throws {
    try Self.fullPaneEnvelope().validateAnchors()
  }

  @Test
  func validateAnchorsRejectsPaneEventMissingTab() throws {
    let env = HookEnvelope(
      event: .paneReady,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: nil,
      pane: .init(id: PaneID(), workingDirectory: "/"),
      data: .paneReady(pid: nil, shell: "/bin/sh")
    )
    #expect(throws: HookEnvelope.ValidationError.self) {
      try env.validateAnchors()
    }
  }

  @Test
  func validateAnchorsRejectsKindMismatch() throws {
    let env = HookEnvelope(
      event: .paneReady,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: .init(id: TabID()),
      pane: .init(id: PaneID(), workingDirectory: "/"),
      data: .paneCrashed(reason: "mismatch")
    )
    #expect(throws: HookEnvelope.ValidationError.kindMismatch(envelope: .paneReady, data: .paneCrashed)) {
      try env.validateAnchors()
    }
  }

  @Test
  func missingOptionalAnchorsEncodeElided() throws {
    let env = HookEnvelope(
      event: .worktreeActivated,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      data: .worktreeActivated(previousWorktreeID: nil)
    )
    let data = try JSONEncoder().encode(env)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("\"pane\""))
    #expect(!json.contains("\"tab\""))
  }

  static func fullPaneEnvelope() -> HookEnvelope {
    HookEnvelope(
      event: .paneOutputMatch,
      timestamp: Date(timeIntervalSince1970: 1700000000),
      space: .init(id: SpaceID(), name: "work"),
      project: .init(id: ProjectID(), name: "touch-code", rootPath: "/repo"),
      worktree: .init(id: WorktreeID(), name: "exp/test", path: "/wt", branch: "exp/test"),
      tab: .init(id: TabID(), name: "agent", selectedPaneID: PaneID()),
      pane: .init(id: PaneID(), workingDirectory: "/wt", initialCommand: nil, labels: ["agent"]),
      data: .paneOutputMatch(
        match: "READY",
        matchedRange: HookMatchRange(start: 0, length: 5),
        output: Data("READY FOR REVIEW".utf8),
        outputBytes: 16
      )
    )
  }
}
