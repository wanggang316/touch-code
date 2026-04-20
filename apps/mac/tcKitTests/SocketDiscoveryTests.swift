import Foundation
import Testing

@testable import tcKit

struct SocketDiscoveryTests {
  @Test
  func defaultPathIncludesUID() {
    let path = SocketDiscovery.defaultSocketPath(uid: 1234)
    #expect(path == "/tmp/touch-code-1234.sock")
  }

  @Test
  func overrideWinsWhenNonEmpty() {
    #expect(SocketDiscovery.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }

  @Test
  func emptyOverrideFallsBackToDefault() {
    let fallback = SocketDiscovery.resolve(override: "")
    #expect(fallback.hasPrefix("/tmp/touch-code-"))
    #expect(fallback.hasSuffix(".sock"))
  }

  @Test
  func isReachableReturnsFalseForMissingPath() {
    let absent = "/tmp/touch-code-tests-\(UUID().uuidString).sock"
    #expect(SocketDiscovery.isReachable(path: absent) == false)
  }
}
