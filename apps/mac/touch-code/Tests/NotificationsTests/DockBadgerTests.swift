import Foundation
import Testing

@testable import touch_code

struct DockBadgerRenderTests {
  @Test
  func rendersNilForZero() {
    #expect(AppKitDockBadger.render(0) == nil)
    #expect(AppKitDockBadger.render(-1) == nil)
  }

  @Test
  func rendersDecimalForSmallCounts() {
    #expect(AppKitDockBadger.render(1) == "1")
    #expect(AppKitDockBadger.render(7) == "7")
    #expect(AppKitDockBadger.render(99) == "99")
  }

  @Test
  func rendersPlusFor100OrMore() {
    #expect(AppKitDockBadger.render(100) == "99+")
    #expect(AppKitDockBadger.render(9999) == "99+")
  }
}
