import SwiftUI
import TouchCodeCore

/// Leading-edge icon for a Sidebar Worktree row. Replaces the old `circle.fill`/`circle`
/// selection dot with a GitHub-style glyph that doubles as the row's PR-state signal:
///
/// - No PR snapshot → `git-branch` tinted by `roleTint` (yellow for main checkout,
///   orange for user-pinned rows, secondary otherwise). Desaturates to secondary when
///   the row is selected — `listRowBackground` already shows selection, so a loud icon
///   would fight the highlight.
/// - PR snapshot     → `git-pull-request`, `git-merge`, `git-pull-request-closed`, or
///   `git-pull-request-draft`, tinted by PR state (green / purple / red / grey). PR
///   state is the dominant signal when a PR exists; the role tint is suppressed.
///
/// A 10×10 circle overlays the bottom-right corner when the aggregated check rollup is
/// non-empty, so the row can surface CI health at a glance without expanding the popover.
struct WorktreeRowIcon: View {
  let snapshot: PullRequestSnapshot?
  let rollup: PullRequestBadge.CheckRollup
  let isSelected: Bool
  /// Fallback tint applied when no PR snapshot is available. Encodes the Worktree's
  /// "role" in the Project — yellow for the main checkout, orange for pinned rows,
  /// secondary for everything else.
  var roleTint: Color = .secondary
  /// `true` when this row is the Project's main checkout. Flips the glyph to a filled
  /// star so main reads as the anchor of the project's worktree list even when it
  /// happens to carry an open PR (rare; the star wins over the PR-state octicon).
  var isMainCheckout: Bool = false

  var body: some View {
    iconView
      .foregroundStyle(tint)
      .overlay(alignment: .bottomTrailing) { rollupBadge }
      .accessibilityLabel(accessibilityLabel)
  }

  /// The main-checkout row gets an SF Symbol star rather than an octicon — position
  /// (always first) plus the yellow tint plus the star shape makes it unambiguous.
  /// Every other row renders the GitHub-style git glyph for its PR state (or the
  /// neutral `git-branch` when no PR exists).
  @ViewBuilder
  private var iconView: some View {
    if isMainCheckout {
      Image(systemName: "star.fill")
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    } else {
      Image(assetName)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
  }

  private var assetName: String {
    guard let snapshot else { return "git-branch" }
    return snapshot.state.rowIconName(isDraft: snapshot.isDraft)
  }

  private var tint: Color {
    if let snapshot {
      return snapshot.state.rowTint(isDraft: snapshot.isDraft)
    }
    if isSelected { return .secondary }
    return roleTint
  }

  @ViewBuilder
  private var rollupBadge: some View {
    switch rollup {
    case .allPassing:
      rollupGlyph(symbol: "checkmark.circle.fill", color: CheckRollupColor.passing)
    case .anyFailing:
      rollupGlyph(symbol: "xmark.circle.fill", color: CheckRollupColor.failing)
    case .anyPending:
      rollupGlyph(symbol: "clock.circle.fill", color: CheckRollupColor.pending)
    case .noChecks:
      EmptyView()
    }
  }

  private func rollupGlyph(symbol: String, color: Color) -> some View {
    Image(systemName: symbol)
      .resizable()
      .frame(width: 10, height: 10)
      .symbolRenderingMode(.palette)
      .foregroundStyle(color, Color(nsColor: .windowBackgroundColor))
      .offset(x: 3, y: 3)
      .accessibilityHidden(true)
  }

  private var accessibilityLabel: Text {
    guard let snapshot else {
      return Text(isSelected ? "Active worktree branch" : "Worktree branch")
    }
    let stateWord: String = {
      if snapshot.isDraft { return "draft" }
      switch snapshot.state {
      case .open: return "open"
      case .merged: return "merged"
      case .closed: return "closed"
      }
    }()
    return Text("\(stateWord) pull request #\(snapshot.number)")
  }
}
