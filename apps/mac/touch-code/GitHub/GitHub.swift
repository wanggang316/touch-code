import Foundation

/// Namespace for the in-app GitHub integration module.
///
/// The module wraps the `gh` CLI to surface PR-centric information (status, checks,
/// merge / close actions) for each Worktree. See `docs/design-docs/github-integration.md`
/// for the design and `docs/exec-plans/0012-github-integration.md` for the execution plan.
///
/// Dependency rules (folder-level, enforced by review per `docs/architecture.md`):
/// - May import `Foundation`, `TouchCodeCore`, and `touch-code/Process/` (`CommandRunner`).
/// - Must not import `touch-code/Git/`, `touch-code/Runtime/`, `touch-code/Hooks/`, SwiftUI,
///   or TCA. The app-layer TCA wrapper lives in `App/Clients/GitHubClient.swift` and
///   `App/Features/GitHub/`.
public enum GitHub {}
