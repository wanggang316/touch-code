import Foundation
import TouchCodeCore

/// Builds the `cd <abs-path> && git …` shell command surfaced by `LargeDiffPlaceholderView`
/// when a diff exceeds the 50 000-line cap. Pure — no I/O, no dependencies.
///
/// The command always begins with `cd '<abs-path>' && ` so the paste works regardless of the
/// target terminal's CWD. `<abs-path>` is POSIX-single-quoted: wrapped in `'…'` with internal
/// `'` rewritten as `'\''` (standard POSIX sh escaping — terminate the quoted region, insert
/// a literal backslash-apostrophe, reopen the quoted region).
///
/// `nonisolated` because every call is a pure value transformation; tests and reducers
/// invoke it off the main actor.
nonisolated enum LargeDiffCommand {
  static func build(scope: DiffScope, worktreePath: String, sha: String? = nil) throws -> String {
    let quoted = posixSingleQuote(worktreePath)
    switch scope {
    case .working:
      return "cd \(quoted) && git diff --no-color"
    case .staged:
      return "cd \(quoted) && git diff --no-color --cached"
    case .commit(let scopeSha):
      // Prefer the scope-embedded SHA; the explicit parameter is a convenience for callers
      // that don't unwrap the scope.
      let resolved = sha ?? scopeSha
      // Commit SHAs reach this builder from `commitSelected` which already validates via
      // `GitShaValidator.isValid`, but a programmer error upstream could still surface a
      // tainted SHA here — treat it as a fatal bug rather than emit a shell command that
      // interpolates untrusted text into `git show`.
      precondition(GitShaValidator.isValid(resolved), "LargeDiffCommand refuses to build shell for invalid SHA: \(resolved)")
      return "cd \(quoted) && git show --no-color \(resolved)"
    case .log:
      // Log scope paginates 100 commits at a time and never hits the cap. Calling with .log
      // is a programmer error — throw so it's caught in tests rather than producing a
      // command that silently opens the first 100 commits.
      throw LargeDiffCommandError.logScopeUnsupported
    }
  }

  /// POSIX-single-quote escaping. `'` inside the string becomes `'\''`:
  /// - close the quote
  /// - insert an escaped `\'`
  /// - reopen the quote
  /// Non-ASCII characters and shell metacharacters (`$`, `` ` ``, `*`, etc.) are safe because
  /// single quotes in POSIX sh suppress all expansion.
  static func posixSingleQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

nonisolated enum LargeDiffCommandError: Error, Equatable {
  /// `.log` scope doesn't render a monolithic diff — pagination avoids the cap entirely.
  case logScopeUnsupported
}
