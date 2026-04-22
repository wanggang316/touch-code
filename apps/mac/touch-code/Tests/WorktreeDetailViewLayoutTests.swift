import CoreGraphics
import Testing

@testable import touch_code

/// T3 unit test for the overlay width clamp. Keeps the threshold
/// unit-testable without SwiftUI layout plumbing — the layout host
/// (`WorktreeDetailView.overlayContent`) consults `shouldShowOverlay` inside
/// a `GeometryReader`, so this coverage is sufficient to guarantee that
/// widening / narrowing the window toggles the overlay exactly at the
/// documented threshold.
struct WorktreeDetailViewLayoutTests {
  @Test
  func overlayShowsAtOrAboveThreshold() {
    // Threshold = gvOverlayMinTerminalWidth (480) + gvOverlayWidth (360) = 840.
    #expect(WorktreeDetailView.shouldShowOverlay(totalWidth: 840))
    #expect(WorktreeDetailView.shouldShowOverlay(totalWidth: 841))
    #expect(WorktreeDetailView.shouldShowOverlay(totalWidth: 1_200))
  }

  @Test
  func overlayHiddenBelowThreshold() {
    #expect(!WorktreeDetailView.shouldShowOverlay(totalWidth: 839))
    #expect(!WorktreeDetailView.shouldShowOverlay(totalWidth: 479))
    #expect(!WorktreeDetailView.shouldShowOverlay(totalWidth: 0))
  }
}
