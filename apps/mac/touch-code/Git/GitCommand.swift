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
  static func diff(kind: DiffKind, ignoreWhitespace: Bool = false) -> [String] {
    let base: [String]
    switch kind {
    case .workingTree:
      base = [
        "-c", "core.quotePath=false",
        "diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3",
      ]
    case .staged:
      base = [
        "-c", "core.quotePath=false",
        "diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--cached",
      ]
    case .commit(let sha):
      // `git show` emits the unified-diff stream; `--format=` drops the commit header the
      // caller already has via log. Trailing `--` disambiguates SHA from path.
      base = [
        "-c", "core.quotePath=false",
        "show", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--format=", sha, "--",
      ]
    }
    return ignoreWhitespace ? base + ["-w"] : base
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
