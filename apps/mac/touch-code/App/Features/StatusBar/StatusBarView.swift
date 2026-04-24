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
    Group {
      switch form {
      case .toast(let toast):
        StatusToastView(toast: toast)
          .transition(.opacity)
      case .pullRequest(let snapshot):
        StatusPullRequestView(snapshot: snapshot, store: gitHubStore)
          .transition(.opacity)
      case .empty:
        // M1 skeleton placeholder — motivational form lands in M5.
        Color.clear.frame(width: 1, height: 1)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: formIdentity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("status.bar")
  }

  /// Priority resolution. Toast always wins; otherwise a non-closed
  /// `PullRequestSnapshot` for the active Worktree takes the slot; else empty.
  enum Form: Equatable {
    case toast(StatusToast)
    case pullRequest(PullRequestSnapshot)
    case empty
  }

  private var form: Form {
    if let toast = store.toast { return .toast(toast) }
    if let wt = worktreeID,
      let snapshot = gitHubStore.snapshots[wt],
      snapshot.state != .closed
    {
      return .pullRequest(snapshot)
    }
    return .empty
  }

  /// Cheap equality-stable token for the form animation. The SwiftUI
  /// `.animation(_:value:)` trigger compares this, so we don't attempt to
  /// compare the whole `PullRequestSnapshot` (which has a `Date` field
  /// that can change every refresh without visually changing the form).
  private var formIdentity: String {
    switch form {
    case .toast(let t): return "toast-\(t.message)"
    case .pullRequest(let pr): return "pr-\(pr.number)-\(pr.state.rawValue)"
    case .empty: return "empty"
    }
  }
}
