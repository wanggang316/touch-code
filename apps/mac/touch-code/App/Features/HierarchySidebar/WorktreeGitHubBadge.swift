import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Sidebar-row GitHub badge with hover-triggered popover. Click on the badge opens the PR
/// on github.com; dwelling the cursor over the badge for 150 ms opens the rich
/// `PullRequestPopover` in place. The popover stays visible while the cursor is over
/// either the badge or the popover content — a 150 ms grace period covers the hand-off
/// between them so the popover does not flash away when the cursor transitions.
///
/// Per-row view so each instance carries its own `@State` (hover flags + debounce Task).
/// The parent `HierarchySidebarView` supplies the popover content as a `@ViewBuilder`
/// closure so the rich action surface keeps its dependency on `SettingsStore` without
/// this view needing to know.
struct WorktreeGitHubBadge<PopoverContent: View>: View {
  let store: StoreOf<GitHubFeature>
  let worktreeID: WorktreeID
  let branch: String
  let worktreePath: URL
  @ViewBuilder let popoverContent: () -> PopoverContent

  @State private var isBadgeHovered = false
  @State private var isPopoverHovered = false
  @State private var hoverTask: Task<Void, Never>?

  private static var hoverDelay: Duration { .milliseconds(150) }

  var body: some View {
    let snapshot = store.snapshots[worktreeID]
    let isLoading = store.loading.contains(worktreeID)
    let lastError = store.lastError[worktreeID]

    Group {
      if let snapshot {
        let checks = store.checks[snapshot.number] ?? []
        let rollup = PullRequestBadge.CheckRollup.from(checks: checks)
        HStack(spacing: 6) {
          diffStatsLabel(snapshot: snapshot)
          PullRequestBadge(
            state: .loaded(snapshot, rollup: rollup),
            onTap: { store.send(.delegate(.openURL(snapshot.url))) }
          )
        }
      } else if isLoading {
        PullRequestBadge(state: .loading, onTap: {})
      } else if let lastError {
        PullRequestBadge(
          state: .error(lastError),
          onTap: {
            store.send(.refreshRequested(worktreeID, branch: branch, worktreePath: worktreePath))
          }
        )
      } else {
        EmptyView()
      }
    }
    .onHover { hovering in
      isBadgeHovered = hovering
      reconcileHover()
    }
    .task(id: BadgeTaskIdentity(worktreeID: worktreeID, branch: branch, path: worktreePath)) {
      store.send(.worktreeBecameVisible(worktreeID, branch: branch, worktreePath: worktreePath))
    }
    .popover(
      isPresented: Binding(
        get: { store.popoverTarget == worktreeID },
        set: { if !$0 { store.send(.dismissPopover) } }
      ),
      arrowEdge: .trailing
    ) {
      popoverContent()
        .onHover { hovering in
          isPopoverHovered = hovering
          reconcileHover()
        }
    }
  }

  /// Compact `+N −M` patch-size indicator for a PR snapshot. Hidden when both counts
  /// are zero (a fresh branch / empty PR renders no noise). Reads from the snapshot's
  /// cached `additions` / `deletions` — no extra gh or git call.
  @ViewBuilder
  private func diffStatsLabel(snapshot: PullRequestSnapshot) -> some View {
    if snapshot.additions > 0 || snapshot.deletions > 0 {
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

  /// Re-evaluates the "should popover be visible" state and schedules a 150 ms debounce
  /// either direction. The cached `hoverTask` is cancelled on every call so rapid hover
  /// transitions collapse into the latest intent instead of queueing a flap.
  private func reconcileHover() {
    hoverTask?.cancel()
    let isTarget = store.popoverTarget == worktreeID
    let shouldShow = isBadgeHovered || isPopoverHovered
    if shouldShow, !isTarget {
      hoverTask = Task { @MainActor in
        try? await Task.sleep(for: Self.hoverDelay)
        if Task.isCancelled { return }
        store.send(.presentPopover(worktreeID, worktreePath: worktreePath))
      }
    } else if !shouldShow, isTarget {
      hoverTask = Task { @MainActor in
        try? await Task.sleep(for: Self.hoverDelay)
        if Task.isCancelled { return }
        store.send(.dismissPopover)
      }
    }
  }
}

/// Composite identity used by `.task(id:)` so a change to branch *or* path (a Worktree
/// whose branch is re-pointed without the WorktreeID changing) re-fires the snapshot
/// fetch. A plain `WorktreeID` would keep serving stale data.
private struct BadgeTaskIdentity: Hashable {
  let worktreeID: WorktreeID
  let branch: String
  let path: URL
}
