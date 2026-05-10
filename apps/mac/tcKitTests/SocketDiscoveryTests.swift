import Foundation
import Testing

@testable import tcKit

struct SocketDiscoveryTests {
  @Test
  func channelPathsIncludeUID() {
    #expect(SocketDiscovery.productionSocketPath(uid: 1234) == "/tmp/touch-code-1234.sock")
    #expect(SocketDiscovery.developmentSocketPath(uid: 1234) == "/tmp/touch-code-dev-1234.sock")
  }

  @Test
  func defaultPathMatchesBuildChannel() {
    let path = SocketDiscovery.defaultSocketPath(uid: 1234)
    #if DEBUG
      #expect(path == "/tmp/touch-code-dev-1234.sock")
    #else
      #expect(path == "/tmp/touch-code-1234.sock")
    #endif
  }

  @Test
  func overrideWinsWhenNonEmpty() {
    #expect(SocketDiscovery.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }

  @Test
  func emptyOverrideFallsBackToDefault() {
    let fallback = SocketDiscovery.resolve(override: "")
    #if DEBUG
      #expect(fallback.hasPrefix("/tmp/touch-code-dev-"))
    #else
      #expect(fallback.hasPrefix("/tmp/touch-code-"))
    #endif
    #expect(fallback.hasSuffix(".sock"))
  }

  @Test
  func isReachableReturnsFalseForMissingPath() {
    let absent = "/tmp/touch-code-tests-\(UUID().uuidString).sock"
    #expect(SocketDiscovery.isReachable(path: absent) == false)
  }
}
