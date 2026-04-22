import Foundation
import Testing

@testable import touch_code

struct DefaultRulesTests {
  @Test
  func bundledJSONIsValidJSONAndContainsAllKnownAgents() throws {
    let data = Data(DefaultRules.json.utf8)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(obj != nil)
    #expect(obj?["version"] as? Int == 1)
    #expect(obj?["idleThresholdSeconds"] as? Double == 120)

    let rules = obj?["rules"] as? [[String: Any]] ?? []
    let agents = Set(rules.compactMap { $0["agent"] as? String })
    #expect(agents == ["claude", "codex", "aider"])

    // Every rule must have the non-negotiable keys per design §Detection Rule DSL.
    for rule in rules {
      #expect(rule["id"] is String)
      #expect(rule["appliesWhen"] is [String: Any])
      #expect(rule["transitionTo"] is String)
      #expect(rule["title"] is String)
      #expect(rule["body"] is String)
    }
  }

  @Test
  func installIfMissingWritesWhenAbsent() throws {
    let dir = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("detection-rules.json")
    #expect(FileManager.default.fileExists(atPath: url.path) == false)

    try DefaultRules.installIfMissing(at: url)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let written = try Data(contentsOf: url)
    #expect(written == Data(DefaultRules.json.utf8))
  }

  @Test
  func installIfMissingIsNoopWhenUserFileExists() throws {
    let dir = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("detection-rules.json")
    try Data("user edited".utf8).write(to: url)

    try DefaultRules.installIfMissing(at: url)
    let after = try Data(contentsOf: url)
    #expect(after == Data("user edited".utf8))
  }

  @Test
  func installIfMissingCreatesIntermediateDirectories() throws {
    let dir = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nested =
      dir
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("detection-rules.json")

    try DefaultRules.installIfMissing(at: nested)
    #expect(FileManager.default.fileExists(atPath: nested.path))
  }

  private static func tempDirectory() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("default-rules-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }
}
