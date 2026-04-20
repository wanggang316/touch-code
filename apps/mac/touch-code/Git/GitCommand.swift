import Foundation

/// Argv builder for the Git CLI. Each static method produces the arguments passed to `git` —
/// never to a shell. `gitExecutable` itself is argv[0] on the Process side; these arrays
/// supply argv[1...].
///
/// Every command that emits path bytes includes `-c core.quotePath=false` so non-ASCII paths
/// arrive as UTF-8 rather than octal escapes. Read-only operations only: `log`, `diff`,
/// `show`, `status`, `rev-parse`.
///
/// `nonisolated` — pure argv construction with no actor concerns.
nonisolated enum GitCommand {
  /// `git log --pretty=format:… --no-color -z --date=iso-strict -n <limit> [--skip <offset>]`
  static func log(limit: Int, skip: Int) -> [String] {
    precondition(limit > 0, "log limit must be positive")
    precondition(skip >= 0, "log skip must be non-negative")
    var args: [String] = [
      "-c", "core.quotePath=false",
      "log",
      "--pretty=format:%H%x00%an%x00%ae%x00%aI%x00%s%x00%P",
      "--no-color",
      "-z",
      "--date=iso-strict",
      "-n",
      String(limit),
    ]
    if skip > 0 {
      args.append(contentsOf: ["--skip", String(skip)])
    }
    return args
  }

  enum DiffKind {
    case workingTree
    case staged
    case commit(sha: String)
  }

  /// `git diff` / `git diff --cached` / `git show <sha>` argv. For `.commit`, the SHA is
  /// followed by `--` to close the SHA/path ambiguity per git's documented argv grammar.
  ///
  /// Correctness note: every flag (`-w`, `-M`, `-C`, `-U3`, `--cached`) must precede the
  /// `--` separator. Tokens after `--` are interpreted as pathspec — a bug in the first
  /// M4a cut of this file placed `-w` after `--` for `.commit`, silently creating a path
  /// filter named `-w` instead of enabling ignore-whitespace. See 0005 DEC-19.
  static func diff(kind: DiffKind, ignoreWhitespace: Bool = false) -> [String] {
    var args: [String] = ["-c", "core.quotePath=false"]
    let whitespaceFlags: [String] = ignoreWhitespace ? ["-w"] : []

    switch kind {
    case .workingTree:
      args += ["diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3"]
      args += whitespaceFlags
    case .staged:
      args += ["diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--cached"]
      args += whitespaceFlags
    case .commit(let sha):
      // `git show` emits the unified-diff stream; `--format=` drops the commit header the
      // caller already has via log. `-w` (when set) lands BEFORE the SHA + `--` trailer —
      // git treats anything after `--` as pathspec.
      args += ["show", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--format="]
      args += whitespaceFlags
      args += [sha, "--"]
    }
    return args
  }

  static func status() -> [String] {
    [
      "-c", "core.quotePath=false",
      "status", "--porcelain=v1", "-z", "--untracked-files=all",
    ]
  }

  /// `git rev-parse --is-inside-work-tree`. Exit 0 + `"true"` on stdout = inside a work tree;
  /// any non-zero exit = not a repo. Used by `LiveGitService.ensureIsRepo`.
  static func revParseIsInsideWorkTree() -> [String] {
    ["rev-parse", "--is-inside-work-tree"]
  }

  /// `git rev-parse --show-toplevel`. Reserved for a future worktree-root discovery helper;
  /// not called from M2's service paths but documented as available.
  static func revParseShowToplevel() -> [String] {
    ["rev-parse", "--show-toplevel"]
  }
}
