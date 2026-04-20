import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore
@testable import TouchCodeIPC

struct HookActionCodableTests {
  @Test
  func everyVariantRoundTrips() throws {
    let variants: [HookAction] = [
      .panelSend(PanelID(), text: "hi", raw: false),
      .panelBroadcast(scope: .tab(TabID()), text: "all", raw: true),
      .panelBroadcast(scope: .label("agent"), text: "agents", raw: false),
      .panelOpen(in: WorktreeID(), tab: TabID(), workingDirectory: "/tmp", initialCommand: "echo"),
      .panelClose(PanelID()),
      .tabActivate(TabID()),
      .tabCreate(in: WorktreeID(), name: "agent"),
      .worktreeActivate(WorktreeID()),
      .notify(title: "Done", body: "Agent finished", panelID: PanelID()),
      .log(level: "info", message: "hook fired"),
      .setPanelLabels(PanelID(), ["agent", "claude"]),
    ]
    for variant in variants {
      let data = try JSONEncoder().encode(variant)
      let decoded = try JSONDecoder().decode(HookAction.self, from: data)
      #expect(decoded == variant, "\(variant.kind) did not round-trip")
    }
  }

  @Test
  func broadcastScopeEncodesIdenticallyAcrossSurfaces() throws {
    // DEC-12: HookAction.panelBroadcast(scope:...) and
    // terminal.broadcastInput request must share identical wire bytes for
    // the scope sub-object. This guards against schema drift between the
    // two surfaces.
    let scope = IPC.BroadcastScope.label("agent")

    let action = HookAction.panelBroadcast(scope: scope, text: "x", raw: false)
    let actionData = try JSONEncoder().encode(action)
    let actionJSON = String(bytes: actionData, encoding: .utf8) ?? ""
    #expect(actionJSON.contains("\"kind\":\"label\""))
    #expect(actionJSON.contains("\"target\":\"agent\""))

    // Direct IPC.BroadcastScope encoding produces the same fields.
    let scopeData = try JSONEncoder().encode(scope)
    let scopeJSON = String(bytes: scopeData, encoding: .utf8) ?? ""
    #expect(scopeJSON.contains("\"kind\":\"label\""))
    #expect(scopeJSON.contains("\"target\":\"agent\""))
  }

  @Test
  func decoderRejectsUnknownKind() throws {
    let bad = Data(#"{"kind":"panel.reticulate"}"#.utf8)
    #expect(throws: HookAction.DecodingIssue.unknownKind("panel.reticulate")) {
      _ = try JSONDecoder().decode(HookAction.self, from: bad)
    }
  }
}
