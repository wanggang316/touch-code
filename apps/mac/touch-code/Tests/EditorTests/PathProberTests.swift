import Foundation
import Testing
@testable import touch_code

struct PathProberTests {
  @Test
  func livePathProberReturnsNilWhenPathUnset() {
    let prober = LivePathProber(environment: [:])
    #expect(prober.locate(binaryName: "nonexistent-xyz") == nil)
  }

  @Test
  func livePathProberLocatesOpenOnRealSystem() {
    let prober = LivePathProber()
    let url = prober.locate(binaryName: "open")
    #expect(url != nil)
    #expect(url?.lastPathComponent == "open")
  }

  @Test
  func livePathProberReturnsNilForMissingBinary() {
    let prober = LivePathProber()
    #expect(prober.locate(binaryName: "totally-not-a-real-binary-42") == nil)
  }

  @Test
  func livePathProberHonoursAbsolutePathExecutableCheck() {
    let prober = LivePathProber()
    // /usr/bin/open is always executable on macOS.
    let openURL = prober.locate(binaryName: "/usr/bin/open")
    #expect(openURL?.path == "/usr/bin/open")
    // /etc/hosts exists but is not executable.
    let hostsURL = prober.locate(binaryName: "/etc/hosts")
    #expect(hostsURL == nil)
  }

  @Test
  func fakePathProberReturnsResolvedValues() {
    let fake = FakePathProber(resolution: [
      "code": URL(fileURLWithPath: "/usr/local/bin/code"),
      "missing": nil,
    ])
    #expect(fake.locate(binaryName: "code")?.path == "/usr/local/bin/code")
    #expect(fake.locate(binaryName: "missing") == nil)
    #expect(fake.locate(binaryName: "unknown") == nil)
  }
}
