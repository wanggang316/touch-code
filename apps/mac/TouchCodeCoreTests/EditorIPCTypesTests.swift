import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC

/// C8a Phase 3 placeholder: the IPC DTO shape is still in flux (Phase 4c rewrites the
/// wire types). The previous suite exercised `EditorInstallationStatusDTO`, which is
/// removed, and asserted on `argv` / `CommandTemplate` fields that are retired. Full
/// coverage returns in Phase 6 against the final shape.
struct EditorIPCTypesTests {
  @Test
  func openRequestRoundTripPreservesPath() throws {
    let request = EditorOpenRequest(
      worktreeID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
      preferred: "zed",
      panelID: nil,
      path: "/tmp/repo/sub/dir"
    )
    let decoded = try Self.roundTrip(request)
    #expect(decoded == request)
    #expect(decoded.path == "/tmp/repo/sub/dir")
    #expect(decoded.preferred == "zed")
  }

  @Test
  func openRequestDecodesLegacyPayloadWithoutPathField() throws {
    let legacy = #"{"worktreeID":"11111111-1111-1111-1111-111111111111","preferred":"vscode"}"#
    let data = Data(legacy.utf8)
    let decoded = try JSONDecoder().decode(EditorOpenRequest.self, from: data)
    #expect(decoded.worktreeID?.uuidString == "11111111-1111-1111-1111-111111111111")
    #expect(decoded.preferred == "vscode")
    #expect(decoded.path == nil)
    #expect(decoded.panelID == nil)
  }

  private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
