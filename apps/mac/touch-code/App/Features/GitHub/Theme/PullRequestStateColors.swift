import SwiftUI
import TouchCodeCore

/// Semantic colour tokens for the GitHub integration. GitHub's web palette at ~80% saturation
/// so the badges cohabit with touch-code's muted sidebar chrome. State hues match GitHub's
/// convention (green open, gray draft, purple merged, dim closed); check hues follow the
/// conventional green / red / yellow.
///
/// Defined as computed `Color` statics (rather than asset-catalog entries) to land the M4
/// slice without touching Assets.xcassets. A later polish pass can promote these into the
/// catalog for proper Dark / HighContrast variants — the call sites will not change.
nonisolated enum PullRequestStateColor {
  static let openFill = Color(red: 0.25, green: 0.55, blue: 0.30)
  static let draftFill = Color(red: 0.45, green: 0.48, blue: 0.50)
  static let mergedFill = Color(red: 0.45, green: 0.32, blue: 0.60)
  static let closedFill = Color(red: 0.55, green: 0.22, blue: 0.22)

  static let onFillPrimary = Color.white
  static let onFillSecondary = Color.white.opacity(0.82)
}

/// Colour tokens for the check aggregate glyph on the badge and the per-row glyph in the
/// popover's check list.
nonisolated enum CheckRollupColor {
  static let passing = Color.green
  static let failing = Color.red
  static let pending = Color.yellow
  static let neutral = Color.gray
}

extension PullRequestState {
  /// Background fill for the badge capsule.
  nonisolated var badgeFill: Color {
    switch self {
    case .open: return PullRequestStateColor.openFill
    case .merged: return PullRequestStateColor.mergedFill
    case .closed: return PullRequestStateColor.closedFill
    }
  }

  /// SF Symbol for the left glyph of the badge. `isDraft` is handled separately because it
  /// modifies the symbol variant without changing the enum case.
  nonisolated func badgeSymbol(isDraft: Bool) -> String {
    switch self {
    case .open: return isDraft ? "arrow.triangle.pull" : "arrow.triangle.pull"
    case .merged: return "checkmark.circle.fill"
    case .closed: return "xmark.circle.fill"
    }
  }
}
