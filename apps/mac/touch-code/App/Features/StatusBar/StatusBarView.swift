import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root SwiftUI view for the Worktree Status Bar's center slot. Picks a
/// form by priority:
///   toast (reducer-owned) → PR (derived from GitHubFeature.snapshots)
///   → motivational (M5) / empty (M1 skeleton).
///
/// Mounted via `ToolbarItem(placement: .principal)` in `WorktreeDetailView`
/// with `ToolbarSpacer(.flexible)` on either side to keep the slot centered.
struct StatusBarView: View {
  @Bindable var store: StoreOf<StatusBarFeature>
  let gitHubStore: StoreOf<GitHubFeature>
  /// Active Worktree identifier, nil when selection doesn't resolve one
  /// (sidebar placeholder state). Drives the PR form's snapshot lookup.
  let worktreeID: WorktreeID?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      formContent(compact: false)
      formContent(compact: true)
      Color.clear.frame(width: 0, height: 0)
    }
    .animation(.easeInOut(duration: 0.2), value: formIdentity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("status.bar")
  }

  /// Each form's two width budgets — full (preferred) and compact (when the
  /// titlebar is narrower than the full rendering). `ViewThatFits` picks the
  /// first subview that fits horizontally; if neither fits, the slot
  /// collapses to `Color.clear` so left / right toolbar groups stay anchored.
  @ViewBuilder
  private func formContent(compact: Bool) -> some View {
    switch form {
    case .toast(let toast):
      StatusToastView(toast: toast, compact: compact)
        .transition(.opacity)
    case .pullRequest(let snapshot):
      StatusPullRequestView(snapshot: snapshot, store: gitHubStore, compact: compact)
        .transition(.opacity)
    case .motivational:
      StatusMotivationalView(compact: compact)
        .transition(.opacity)
    }
  }

  /// Priority resolution. Toast always wins; otherwise a non-closed
  /// `PullRequestSnapshot` for the active Worktree takes the slot; else empty.
  enum Form: Equatable {
    case toast(StatusToast)
    case pullRequest(PullRequestSnapshot)
    case motivational
  }

  private var form: Form {
    if let toast = store.toast { return .toast(toast) }
    if let wt = worktreeID,
      let snapshot = gitHubStore.snapshots[wt],
      snapshot.state != .closed
    {
      return .pullRequest(snapshot)
    }
    return .motivational
  }

  /// Cheap equality-stable token for the form animation. The SwiftUI
  /// `.animation(_:value:)` trigger compares this, so we don't attempt to
  /// compare the whole `PullRequestSnapshot` (which has a `Date` field
  /// that can change every refresh without visually changing the form).
  private var formIdentity: String {
    switch form {
    case .toast(let t): return "toast-\(t.message)"
    case .pullRequest(let pr): return "pr-\(pr.number)-\(pr.state.rawValue)"
    case .motivational: return "motivational"
    }
  }
}
