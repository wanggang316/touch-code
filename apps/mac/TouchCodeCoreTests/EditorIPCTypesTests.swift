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

  private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
