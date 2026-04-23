import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC
@testable import touch_code

struct HookActionCodableTests {
  @Test
  func everyVariantRoundTrips() throws {
    let variants: [HookAction] = [
      .paneSend(PaneID(), text: "hi", raw: false),
      .paneBroadcast(scope: .tab(TabID()), text: "all", raw: true),
      .paneBroadcast(scope: .label("agent"), text: "agents", raw: false),
      .paneOpen(in: WorktreeID(), tab: TabID(), workingDirectory: "/tmp", initialCommand: "echo"),
      .paneClose(PaneID()),
      .tabActivate(TabID()),
      .tabCreate(in: WorktreeID(), name: "agent"),
      .worktreeActivate(WorktreeID()),
      .notify(title: "Done", body: "Agent finished", paneID: PaneID()),
      .log(level: "info", message: "hook fired"),
      .setPaneLabels(PaneID(), ["agent", "claude"]),
    ]
    for variant in variants {
      let data = try JSONEncoder().encode(variant)
      let decoded = try JSONDecoder().decode(HookAction.self, from: data)
      #expect(decoded == variant, "\(variant.kind) did not round-trip")
    }
  }

  @Test
  func broadcastScopeEncodesIdenticallyAcrossSurfaces() throws {
    // DEC-12: HookAction.paneBroadcast(scope:...) and
    // terminal.broadcastInput request must share identical wire bytes for
    // the scope sub-object. This guards against schema drift between the
    // two surfaces.
    let scope = IPC.BroadcastScope.label("agent")

    let action = HookAction.paneBroadcast(scope: scope, text: "x", raw: false)
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
    let bad = Data(#"{"kind":"pane.reticulate"}"#.utf8)
    #expect(throws: HookAction.DecodingIssue.unknownKind("pane.reticulate")) {
      _ = try JSONDecoder().decode(HookAction.self, from: bad)
    }
  }
}
