import CoreGraphics
import Testing

@testable import touch_code

/// M1 unit test for the modal-host card sizing clamp. Three regimes per axis
/// (below-min / in-range / above-max) — the rendering body mounts the helper
/// inside a `GeometryReader`, so this coverage is sufficient to guarantee the
/// card frame snaps to the documented bounds without any SwiftUI layout
/// plumbing.
struct GitViewerModalHostSizingTests {
  @Test
  func belowMinReturnsMinOnBothAxes() {
    let size = GitViewerModalHost.cardSize(in: CGSize(width: 200, height: 200))
    #expect(size == CGSize(width: 560, height: 420))
  }

  @Test
  func inRangeReturnsContainerMinusGutterOnBothAxes() {
    // Width:  800 − 2·48 = 704 (in [560, 980] → 704).
    // Height: 600 − 2·56 = 488 (in [420, 760] → 488).
    let size = GitViewerModalHost.cardSize(in: CGSize(width: 800, height: 600))
    #expect(size == CGSize(width: 704, height: 488))
  }

  @Test
  func aboveMaxReturnsCapOnBothAxes() {
    let size = GitViewerModalHost.cardSize(in: CGSize(width: 2_000, height: 1_500))
    #expect(size == CGSize(width: 980, height: 760))
  }
}
