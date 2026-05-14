import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Leading cluster in the worktree detail toolbar. Mirrors the sidebar
/// Worktree row's identity surface so the two read as the same record:
/// the same `WorktreeRowIcon` (PR-state aware, role tint, rollup overlay,
/// unread bell override), the worktree name + pin marker, the branch
/// subtitle (only when it differs from the name — same suppression rule
/// the sidebar uses), the `+N −M` open-PR diff stats, and the `#NN`
/// `PullRequestBadge`. Tapping the PR badge opens the PR on github.com
/// via the same `GitHubFeature.delegate(.openURL)` path the sidebar
/// badge uses, so behaviour stays in sync alongside the visuals.
struct WorktreeHeaderInfoLabel: View {
  let worktree: Worktree
  let project: Project
  let gitHubStore: StoreOf<GitHubFeature>

  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?

  var body: some View {
    let snapshot = gitHubStore.snapshots[worktree.id]
    let rollup: PullRequestBadge.CheckRollup = {
      guard let snapshot else { return .noChecks }
      return PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
    }()
    let isMainCheckout = worktree.path == project.rootPath
    let isSynthetic = isMainCheckout && project.gitRoot == nil
    let roleTint: Color = worktree.isPinned ? .orange : .secondary
    let hasUnread = notificationRollup?.current.unreadWorktrees.contains(worktree.id) == true

    HStack(spacing: 8) {
      WorktreeRowIcon(
        snapshot: snapshot,
        rollup: rollup,
        // Toolbar has no row-selection chrome, so the icon should keep
        // its role tint rather than swap to the selected-text colour
        // the sidebar uses on the active row.
        isSelected: false,
        roleTint: roleTint,
        isMainCheckout: isMainCheckout,
        isSynthetic: isSynthetic,
        hasUnreadNotification: hasUnread
      )
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 2) {
          Text(worktree.name)
            .font(.headline)
            .lineLimit(1)
          if worktree.isPinned && !isMainCheckout {
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
              .accessibilityLabel("Pinned")
          }
        }
        if let branch = worktree.branch, branch != worktree.name {
          Text(branch)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      if let snapshot {
        diffStatsLabel(snapshot: snapshot)
        PullRequestBadge(
          state: .loaded(snapshot, rollup: rollup),
          onTap: { gitHubStore.send(.delegate(.openURL(snapshot.url))) }
        )
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(snapshot: snapshot))
  }

  /// `+N −M` patch-size indicator, gated on `.open` PRs only — closed /
  /// merged PRs hide their counts in the sidebar too (the diff is already
  /// in base or discarded), so the header follows suit.
  @ViewBuilder
  private func diffStatsLabel(snapshot: PullRequestSnapshot) -> some View {
    if snapshot.state == .open, snapshot.additions > 0 || snapshot.deletions > 0 {
      HStack(spacing: 4) {
        if snapshot.additions > 0 {
          Text("+\(snapshot.additions)").foregroundStyle(.green)
        }
        if snapshot.deletions > 0 {
          Text("−\(snapshot.deletions)").foregroundStyle(.red)
        }
      }
      .font(.caption2.monospacedDigit())
      .accessibilityLabel(
        "\(snapshot.additions) additions, \(snapshot.deletions) deletions"
      )
    }
  }

  private func accessibilityLabel(snapshot: PullRequestSnapshot?) -> Text {
    var parts: [String] = [worktree.name]
    if let branch = worktree.branch, branch != worktree.name {
      parts.append("branch \(branch)")
    }
    if let snapshot {
      parts.append("pull request #\(snapshot.number)")
    }
    return Text(parts.joined(separator: ", "))
  }
}
