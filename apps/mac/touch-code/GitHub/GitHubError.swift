import Foundation

/// Failure taxonomy for the GitHub integration. Every public `GitHubService` method throws
/// this; UI code maps each case to a user-facing message via `userFacingMessage`.
///
/// Equatable without associated-value-level comparison for `.other` / `.network` would drop
/// useful diagnostic detail in tests, so those cases compare full strings. The trade-off is
/// intentional: these errors carry stderr / underlying-description text that tests assert on.
enum GitHubError: Error, Equatable, Sendable {
  /// `gh` is not on `$PATH`. Remediation: install via Homebrew or the user's package manager.
  case notInstalled

  /// `gh auth status` reports no logged-in host (or the host the PR lives on is missing).
  /// `host` is `nil` when the probe could not even determine which host was expected.
  case notAuthenticated(host: String?)

  /// The working-tree branch has no open, merged, or closed pull request. Not surfaced to
  /// the user as an error — the sidebar row simply has no badge.
  case notAPullRequest

  /// `gh` exited non-zero and stderr mentions a connectivity problem. The string carries
  /// the stderr tail so logs and tooltips can show the original gh message.
  case network(String)

  /// GitHub's abuse or secondary rate limit was hit. `retryAfter` is parsed from the
  /// `Retry-After` header gh logs when present; `nil` means the header was absent.
  case rateLimited(retryAfter: Duration?)

  /// `gh pr merge` reported the PR is not mergeable (conflicts, branch protection, etc.).
  case mergeConflict

  /// `CommandRunner.run` returned `.timedOut` — the gh subprocess did not complete within
  /// the service's configured timeout. Rare in practice; escalates to a user toast.
  case timeout

  /// Anything else. The string carries stderr or a decoder description so the popover's
  /// error view can still surface something actionable.
  case other(String)

  /// One-line, user-facing string suitable for tooltip + popover banner.
  var userFacingMessage: String {
    switch self {
    case .notInstalled:
      return "GitHub CLI is not installed. Run `brew install gh` in a terminal to enable pull-request features."
    case .notAuthenticated(let host):
      if let host {
        return "Sign in to \(host) by running `gh auth login` in a terminal."
      }
      return "Sign in to GitHub by running `gh auth login` in a terminal."
    case .notAPullRequest:
      return "This branch has no pull request yet."
    case .network(let detail):
      return "GitHub is unreachable: \(detail)"
    case .rateLimited:
      return "GitHub rate limit hit. Try again in a few minutes."
    case .mergeConflict:
      return "This pull request cannot be merged cleanly. Resolve conflicts on GitHub first."
    case .timeout:
      return "The GitHub CLI took too long to respond. Check your network and try again."
    case .other(let detail):
      return "GitHub integration error: \(detail)"
    }
  }
}
