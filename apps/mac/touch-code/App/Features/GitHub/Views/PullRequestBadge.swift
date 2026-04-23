import SwiftUI
import TouchCodeCore

/// Compact trailing-slot badge for a sidebar Worktree row. Renders only when the Worktree
/// has a matched PR — consumers are responsible for not mounting the view when the
/// snapshot is nil.
///
/// Three render states surfaced via `BadgeState`:
///   - `.loaded(snapshot, rollup)` — full render
///   - `.loading` — skeleton outline + progress indicator, suppressed for the first 200 ms
///     so fast responses don't flicker in (consumer-managed)
///   - `.error(GitHubError)` — tertiary-label exclamation with tooltip
struct PullRequestBadge: View {
  enum BadgeState: Equatable {
    case loaded(PullRequestSnapshot, rollup: CheckRollup)
    case loading
    case error(GitHubError)
  }

  enum CheckRollup: Equatable {
    case allPassing
    case anyFailing
    case anyPending
    case noChecks
  }

  let state: BadgeState
  let onTap: () -> Void
  let onCommandTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      content
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .help(tooltip)
    .onModifierTap(.command, perform: onCommandTap)
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .loaded(let snapshot, let rollup):
      loadedBody(snapshot: snapshot, rollup: rollup)
    case .loading:
      loadingBody
    case .error:
      errorBody
    }
  }

  private func loadedBody(snapshot: PullRequestSnapshot, rollup: CheckRollup) -> some View {
    HStack(spacing: 4) {
      Image(systemName: snapshot.state.badgeSymbol(isDraft: snapshot.isDraft))
        .font(.caption2.weight(.semibold))
        .imageScale(.small)
      Text("#\(snapshot.number)")
        .font(.caption2.weight(.semibold))
      rollupGlyph(rollup)
        .imageScale(.small)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .foregroundStyle(
      snapshot.state == .closed
        ? PullRequestStateColor.onFillSecondary
        : PullRequestStateColor.onFillPrimary
    )
    .background(
      Capsule(style: .continuous)
        .fill(snapshot.isDraft ? PullRequestStateColor.draftFill : snapshot.state.badgeFill)
    )
  }

  private var loadingBody: some View {
    HStack(spacing: 4) {
      ProgressView()
        .controlSize(.mini)
      Text("loading")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      Capsule(style: .continuous)
        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
    )
  }

  private var errorBody: some View {
    Image(systemName: "exclamationmark.circle")
      .foregroundStyle(.tertiary)
      .imageScale(.small)
  }

  @ViewBuilder
  private func rollupGlyph(_ rollup: CheckRollup) -> some View {
    switch rollup {
    case .allPassing:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(CheckRollupColor.passing)
    case .anyFailing:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CheckRollupColor.failing)
    case .anyPending:
      Image(systemName: "circle.dotted").foregroundStyle(CheckRollupColor.pending)
    case .noChecks:
      EmptyView()
    }
  }

  private var accessibilityLabel: Text {
    switch state {
    case .loaded(let snapshot, let rollup):
      let stateWord: String = {
        if snapshot.isDraft { return "draft" }
        switch snapshot.state {
        case .open: return "open"
        case .merged: return "merged"
        case .closed: return "closed"
        }
      }()
      let rollupWord: String = {
        switch rollup {
        case .allPassing: return "checks passing"
        case .anyFailing: return "checks failing"
        case .anyPending: return "checks pending"
        case .noChecks: return "no checks"
        }
      }()
      return Text(
        "Pull request \(snapshot.number), \(stateWord), \(rollupWord). Activate to see details."
      )
    case .loading:
      return Text("Loading pull request status")
    case .error(let error):
      return Text("GitHub error: \(error.userFacingMessage)")
    }
  }

  private var tooltip: String {
    switch state {
    case .loaded(let snapshot, _):
      let draftTag = snapshot.isDraft ? " (draft)" : ""
      return "#\(snapshot.number)\(draftTag) \(snapshot.title)\n@\(snapshot.author)"
    case .loading:
      return "Loading pull request status…"
    case .error(let error):
      return error.userFacingMessage
    }
  }
}

private extension View {
  /// Invokes `perform` on tap when the given modifier is held. macOS only — on iOS this
  /// modifier's keypath differs. Implemented as a no-op if the tap-gesture chain can't
  /// observe modifiers. Kept small so the badge view stays self-contained.
  func onModifierTap(
    _ modifier: EventModifiers,
    perform: @escaping () -> Void
  ) -> some View {
    self.simultaneousGesture(
      TapGesture()
        .modifiers(modifier)
        .onEnded { perform() }
    )
  }
}

/// Convenience helper so views can compute the check rollup from a raw check list.
extension PullRequestBadge.CheckRollup {
  static func from(checks: [CheckResult]) -> PullRequestBadge.CheckRollup {
    guard !checks.isEmpty else { return .noChecks }
    if checks.contains(where: {
      if case .completed = $0.status, $0.conclusion == .failure { return true }
      return false
    }) {
      return .anyFailing
    }
    if checks.contains(where: {
      switch $0.status {
      case .inProgress, .queued, .waiting, .pending: return true
      case .completed: return false
      }
    }) {
      return .anyPending
    }
    return .allPassing
  }
}
