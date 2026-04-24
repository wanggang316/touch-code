import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Titlebar-center PR form: `#N` badge + ChecksRollupRing + one-line summary.
///
/// Interactions:
///   * plain click → opens the PR on github.com (same dispatch the sidebar
///     badge uses)
///   * ⌘-hold → summary text swaps to `Open on GitHub ⌘↵`, hinting the
///     click will open the browser
///
/// The click intentionally does not host `PullRequestPopover` today — see
/// ExecPlan 0014 Decision Log, 2026-04-24 (M4.C) for the tradeoff and
/// OQ-7 for the follow-up.
struct StatusPullRequestView: View {
  let snapshot: PullRequestSnapshot
  let store: StoreOf<GitHubFeature>
  /// Collapses the trailing detail text when true. Ring + badge stay so
  /// the slot still carries the CI health signal at a glance.
  var compact: Bool = false
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    Button {
      store.send(.delegate(.openURL(snapshot.url)))
    } label: {
      HStack(spacing: 6) {
        badge
        ChecksRollupRing(checks: snapshot.checkRollup)
        if !compact {
          detailText
            .foregroundStyle(.secondary)
        }
      }
      .font(.footnote)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Pull request #\(snapshot.number)")
    .accessibilityValue(Self.summaryText(snapshot: snapshot))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens on GitHub")
  }

  private var badge: some View {
    Text("#\(snapshot.number)")
      .font(.caption.monospacedDigit().weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        snapshot.state.badgeFill,
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
  }

  @ViewBuilder
  private var detailText: some View {
    if commandKeyObserver.isCommandHeld {
      Text("Open on GitHub \u{2318}\u{21A9}")  // ⌘↵
        .lineLimit(1)
    } else {
      Text(Self.summaryText(snapshot: snapshot))
        .lineLimit(1)
    }
  }

  /// Simple-line summary, in priority order:
  ///   1. Merged / closed state labels
  ///   2. Merge-state blockers (`blocked` / `dirty` / `behind`)
  ///   3. Checks breakdown (failing > pending > all passing)
  ///   4. `(Draft)` marker
  ///   5. PR title (truncated to fit)
  static func summaryText(snapshot: PullRequestSnapshot) -> String {
    if snapshot.state == .merged { return "Merged" }
    if snapshot.state == .closed { return "Closed" }
    switch snapshot.mergeStateStatus {
    case .blocked: return "Blocked"
    case .dirty: return "Merge conflicts"
    case .behind: return "Behind base"
    case .clean, .hasHooks, .unstable, .draft, .unknown: break
    }
    let breakdown = ChecksRollupRing.Breakdown(checks: snapshot.checkRollup)
    if breakdown.failing > 0 { return "\(breakdown.failing) checks failing" }
    if breakdown.pending > 0 { return "\(breakdown.pending) checks pending" }
    if breakdown.passing > 0, breakdown.failing == 0, breakdown.pending == 0 {
      return "All checks passing"
    }
    if snapshot.isDraft { return "(Draft)" }
    return snapshot.title
  }
}
