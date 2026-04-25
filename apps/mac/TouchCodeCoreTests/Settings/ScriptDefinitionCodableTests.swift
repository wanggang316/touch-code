import Foundation
import Testing

@testable import TouchCodeCore

struct ScriptDefinitionCodableTests {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()
  private let decoder = JSONDecoder()

  @Test
  func defaultInitialiserUsesRunKind() {
    let s = ScriptDefinition()
    #expect(s.kind == .run)
    #expect(s.name == "")
    #expect(s.command == "")
    #expect(s.systemImage == nil)
    #expect(s.tintColor == nil)
  }

  @Test
  func roundTripsAcrossEveryScriptKind() throws {
    for kind in ScriptKind.allCases {
      let original = ScriptDefinition(kind: kind, name: kind.defaultName, command: "echo \(kind.rawValue)")
      let data = try encoder.encode(original)
      let decoded = try decoder.decode(ScriptDefinition.self, from: data)
      #expect(decoded == original)
    }
  }

  @Test
  func legacyPayloadWithoutKindDecodesAsRun() throws {
    // Phase 1 reserved-empty payloads: `{ "id": "<uuid>", "name": "x", "command": "y" }`.
    // Decoder defaults `kind` to `.run` so existing settings.json files round-trip.
    let id = UUID()
    let payload = Data(#"""
      { "id": "\#(id.uuidString)", "name": "legacy", "command": "echo hi" }
      """#.utf8)
    let decoded = try decoder.decode(ScriptDefinition.self, from: payload)
    #expect(decoded.id == id)
    #expect(decoded.kind == .run)
    #expect(decoded.name == "legacy")
    #expect(decoded.command == "echo hi")
  }

  @Test
  func displayNameFallsBackToKindDefaultWhenEmpty() {
    let unnamed = ScriptDefinition(kind: .test, name: "", command: "go test ./...")
    #expect(unnamed.displayName == "Test")

    let named = ScriptDefinition(kind: .test, name: "Unit Tests", command: "go test ./...")
    #expect(named.displayName == "Unit Tests")
  }

  @Test
  func resolvedSystemImageIgnoresOverrideForPredefinedKinds() {
    // "Kind is the contract" — a `.test` script always renders with the
    // test icon even if a stale `systemImage` value persists on disk.
    let runScript = ScriptDefinition(
      kind: .run,
      name: "x",
      command: "y",
      systemImage: "questionmark"
    )
    #expect(runScript.resolvedSystemImage == ScriptKind.run.defaultSystemImage)

    let customScript = ScriptDefinition(
      kind: .custom,
      name: "x",
      command: "y",
      systemImage: "star.fill"
    )
    #expect(customScript.resolvedSystemImage == "star.fill")

    let customWithoutOverride = ScriptDefinition(kind: .custom, name: "x", command: "y")
    #expect(customWithoutOverride.resolvedSystemImage == ScriptKind.custom.defaultSystemImage)
  }

  @Test
  func resolvedTintColorIgnoresOverrideForPredefinedKinds() {
    let testScript = ScriptDefinition(
      kind: .test,
      name: "x",
      command: "y",
      tintColor: .red
    )
    #expect(testScript.resolvedTintColor == ScriptKind.test.defaultTintColor)

    let customScript = ScriptDefinition(
      kind: .custom,
      name: "x",
      command: "y",
      tintColor: .purple
    )
    #expect(customScript.resolvedTintColor == .purple)
  }

  @Test
  func encoderOmitsEmptyOptionalFields() throws {
    let s = ScriptDefinition(kind: .run, name: "", command: "")
    let data = try encoder.encode(s)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("\"name\"") == false)
    #expect(text.contains("\"command\"") == false)
    #expect(text.contains("\"systemImage\"") == false)
    #expect(text.contains("\"tintColor\"") == false)
    // id and kind always present.
    #expect(text.contains("\"id\""))
    #expect(text.contains("\"kind\":\"run\""))
  }

  @Test
  func customKindWithIconAndColorEncodesAndRoundTrips() throws {
    let s = ScriptDefinition(
      kind: .custom,
      name: "Tail logs",
      command: "ssh prod 'tail -f /var/log/app.log'",
      systemImage: "doc.text.magnifyingglass",
      tintColor: .blue
    )
    let data = try encoder.encode(s)
    let decoded = try decoder.decode(ScriptDefinition.self, from: data)
    #expect(decoded == s)
    #expect(decoded.resolvedSystemImage == "doc.text.magnifyingglass")
    #expect(decoded.resolvedTintColor == .blue)
  }
}
