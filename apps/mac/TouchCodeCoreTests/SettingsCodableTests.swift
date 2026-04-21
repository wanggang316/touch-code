import Foundation
import Testing

@testable import TouchCodeCore

struct SettingsCodableTests {
  @Test
  func defaultTreeRoundTrips() throws {
    let original = Settings.default
    let data = try JSONEncoder.touchCodeDefault.encode(original)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    #expect(decoded == original)
    #expect(decoded.version == Settings.currentVersion)
    #expect(decoded.version == 2)
  }

  /// Minimal `{"version":2}` must decode into a fully-populated default tree. Protects
  /// against future accidental removal of the `decodeIfPresent` fallbacks.
  @Test
  func minimalVersionOnlyDecodesToDefaults() throws {
    let data = Data(#"{"version":2}"#.utf8)
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    #expect(decoded.general == .default)
    #expect(decoded.notifications == .default)
    #expect(decoded.developer == .default)
    #expect(decoded.repositories.isEmpty)
  }

  /// A well-formed tree that carries a parseable and an unparseable `repositories` key.
  /// The good key survives; the bad one is logged and dropped; the rest of the file decodes.
  @Test
  func repositoriesKeyThatIsNotAUUIDIsDropped() throws {
    let uuid = UUID()
    let json = """
      {
        "version": 2,
        "repositories": {
          "\(uuid.uuidString)": {},
          "not-a-uuid": {}
        }
      }
      """
    let decoded = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.repositories.count == 1)
    #expect(decoded.repositories[ProjectID(raw: uuid)] != nil)
  }

  @Test
  func rejectsUnsupportedVersion() {
    let data = Data(#"{"version":99}"#.utf8)
    #expect(throws: Settings.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
    }
  }

  /// Verifies `repositories` serialises as a JSON object keyed by UUID string, not as the
  /// array-of-pairs layout JSONEncoder falls back to for non-String-keyed dictionaries. This
  /// is the on-disk invariant design §Data Storage relies on for hand-editability.
  @Test
  func repositoriesSerialiseAsUUIDKeyedObject() throws {
    let id = ProjectID()
    var settings = Settings.default
    settings.repositories[id] = RepositorySettings()
    // Bypass garbageCollect so the entry survives for this assertion — the GC behaviour has
    // its own coverage in SettingsStoreTests (Step 4).
    let data = try JSONEncoder.touchCodeDefault.encode(settings)
    let json = try #require(String(data: data, encoding: .utf8))
    // Expect a `"repositories":{"<uuid>":{}}` substring; the sorted-keys encoder produces
    // deterministic output so a direct contains() is safe.
    let expected = "\"repositories\" : {\n    \"\(id.raw.uuidString)\" : {\n\n    }\n  }"
    #expect(json.contains(expected), "Expected UUID-keyed repositories object; got:\n\(json)")
  }
}
