import Foundation
import Testing

@testable import TouchCodeCore

struct HookEnvelopeCodableTests {
  @Test
  func panelScopedEnvelopeRoundTrips() throws {
    let env = Self.fullPanelEnvelope()
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
  func validateAnchorsAcceptsFullPanelEnvelope() throws {
    try Self.fullPanelEnvelope().validateAnchors()
  }

  @Test
  func validateAnchorsRejectsPanelEventMissingTab() throws {
    let env = HookEnvelope(
      event: .panelReady,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: nil,
      panel: .init(id: PanelID(), workingDirectory: "/"),
      data: .panelReady(pid: nil, shell: "/bin/sh")
    )
    #expect(throws: HookEnvelope.ValidationError.self) {
      try env.validateAnchors()
    }
  }

  @Test
  func validateAnchorsRejectsKindMismatch() throws {
    let env = HookEnvelope(
      event: .panelReady,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: .init(id: TabID()),
      panel: .init(id: PanelID(), workingDirectory: "/"),
      data: .panelCrashed(reason: "mismatch")
    )
    #expect(throws: HookEnvelope.ValidationError.kindMismatch(envelope: .panelReady, data: .panelCrashed)) {
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
    #expect(!json.contains("\"panel\""))
    #expect(!json.contains("\"tab\""))
  }

  static func fullPanelEnvelope() -> HookEnvelope {
    HookEnvelope(
      event: .panelOutputMatch,
      timestamp: Date(timeIntervalSince1970: 1700000000),
      space: .init(id: SpaceID(), name: "work"),
      project: .init(id: ProjectID(), name: "touch-code", rootPath: "/repo"),
      worktree: .init(id: WorktreeID(), name: "exp/test", path: "/wt", branch: "exp/test"),
      tab: .init(id: TabID(), name: "agent", selectedPanelID: PanelID()),
      panel: .init(id: PanelID(), workingDirectory: "/wt", initialCommand: nil, labels: ["agent"]),
      data: .panelOutputMatch(
        match: "READY",
        matchedRange: HookMatchRange(start: 0, length: 5),
        output: Data("READY FOR REVIEW".utf8),
        outputBytes: 16
      )
    )
  }
}
