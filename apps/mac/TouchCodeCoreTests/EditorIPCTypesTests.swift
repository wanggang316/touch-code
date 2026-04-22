import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC

/// C8a Phase 4c wire-type round-trip coverage. Placeholder-level: asserts the new request /
/// response shapes encode+decode stably. Deeper coverage (descriptor DTO ↔ app-tier descriptor
/// mapping, error envelope translation) lands in Phase 6 alongside the handler test rebuild.
struct EditorIPCTypesTests {
  @Test
  func openRequestRoundTripPreservesPathAndPreferred() throws {
    let request = EditorOpenRequest(path: "/tmp/repo/sub/dir", preferred: "zed")
    let decoded = try Self.roundTrip(request)
    #expect(decoded == request)
    #expect(decoded.path == "/tmp/repo/sub/dir")
    #expect(decoded.preferred == "zed")
  }

  @Test
  func openRequestRoundTripPreservesNilPreferred() throws {
    let request = EditorOpenRequest(path: "/tmp/repo", preferred: nil)
    let decoded = try Self.roundTrip(request)
    #expect(decoded == request)
    #expect(decoded.preferred == nil)
  }

  @Test
  func descriptorDTORoundTripPreservesLaunchMode() throws {
    let dto = EditorDescriptorDTO(
      id: "cursor",
      displayName: "Cursor",
      bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      launchMode: .directory,
      appURL: URL(fileURLWithPath: "/Applications/Cursor.app"),
      alternateBundleIdentifiers: []
    )
    let decoded = try Self.roundTrip(dto)
    #expect(decoded == dto)
    #expect(decoded.launchMode == .directory)
  }

  @Test
  func shellEditorDescriptorEncodesEmptyBundleAndNilAppURL() throws {
    let dto = EditorDescriptorDTO(
      id: "editor",
      displayName: "$EDITOR",
      bundleIdentifier: "",
      launchMode: .shellEditor,
      appURL: nil
    )
    let decoded = try Self.roundTrip(dto)
    #expect(decoded == dto)
    #expect(decoded.bundleIdentifier.isEmpty)
    #expect(decoded.appURL == nil)
    #expect(decoded.launchMode == .shellEditor)
  }

  @Test
  func setGlobalDefaultRequestRoundTrips() throws {
    let request = EditorSetGlobalDefaultRequest(editorID: "vscode")
    let decoded = try Self.roundTrip(request)
    #expect(decoded == request)
  }

  @Test
  func setProjectDefaultRequestRoundTrips() throws {
    let projectID = UUID()
    let request = EditorSetProjectDefaultRequest(projectID: projectID, editorID: nil)
    let decoded = try Self.roundTrip(request)
    #expect(decoded == request)
    #expect(decoded.editorID == nil)
  }

  private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
