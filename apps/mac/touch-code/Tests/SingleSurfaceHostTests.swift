import Foundation
import Testing
@testable import touch_code

@MainActor
struct SingleSurfaceHostTests {
  @Test
  func bringUpIsIdempotent() {
    let host = SingleSurfaceHost()
    host.bringUp()
    // Either .ready (surface spun up) or .failed (no GhosttyKit in test
    // host) — both are terminal; a second bringUp must not transition
    // back to .loading or create a second runtime.
    let firstPhase = host.phase
    host.bringUp()
    host.bringUp()
    #expect(host.phase == firstPhase)
  }

  @Test
  func tearDownAfterFailedBringUpIsSafe() {
    let host = SingleSurfaceHost()
    host.bringUp()
    host.tearDown()
    host.tearDown()  // second call must not crash
    #expect(host.panel == nil)
  }
}
