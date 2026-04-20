import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC

struct EditorIPCTypesTests {
  @Test
  func installationStatusInstalledRoundTrip() throws {
    let status = EditorInstallationStatusDTO.installed(
      resolvedBinary: URL(fileURLWithPath: "/usr/local/bin/code")
    )
    let decoded = try Self.roundTrip(status)
    #expect(decoded == status)
    if case .installed(let url) = decoded {
      #expect(url.path == "/usr/local/bin/code")
    } else {
      Issue.record("expected .installed")
    }
  }

  @Test
  func installationStatusMissingRoundTrip() throws {
    let status = EditorInstallationStatusDTO.missingBinary(expected: "code")
    let decoded = try Self.roundTrip(status)
    #expect(decoded == status)
    if case .missingBinary(let name) = decoded {
      #expect(name == "code")
    } else {
      Issue.record("expected .missingBinary")
    }
  }

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
  func openRequestOmittedPathDecodesAsNil() throws {
    let request = EditorOpenRequest(
      worktreeID: UUID(),
      preferred: nil,
      panelID: nil,
      path: nil
    )
    let decoded = try Self.roundTrip(request)
    #expect(decoded == request)
    #expect(decoded.path == nil)
  }

  @Test
  func openRequestDecodesLegacyPayloadWithoutPathField() throws {
    // Guards compatibility with any in-flight `tc` build predating the `path` field.
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
