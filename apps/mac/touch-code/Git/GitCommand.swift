import Foundation

/// Argv builder for the Git CLI. Each static method produces the arguments passed to `git` —
/// never to a shell. The first element is intentionally **not** the executable path; the live
/// service prepends that. Keeping commands in one place makes the design's argv table directly
/// reviewable next to the implementation.
///
/// `nonisolated` — pure argv construction with no actor concerns.
nonisolated enum GitCommand {
  /// `git log --pretty=format:… --no-color -z --date=iso-strict -n <limit> [--skip <offset>]`
  ///
  /// The format uses null bytes between fields (`%x00`) and NUL record separators (`-z`), so
  /// the parser is a plain split on `\0`.
  static func log(limit: Int, skip: Int) -> [String] {
    precondition(limit > 0, "log limit must be positive")
    precondition(skip >= 0, "log skip must be non-negative")
    var args = [
      "log",
      // Six fields per commit, null-separated: H, an, ae, aI, s, P. Record terminator is
      // supplied by `-z` (NUL between records, not by the format itself).
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

  /// `git diff` / `git diff --cached` / `git show <sha>` argv. The design prefers a single
  /// `diff` invocation parameterised by `--cached`; for a specific commit we use `show` which
  /// emits the same unified-diff shape with the commit's own `<sha>^..<sha>`.
  static func diff(kind: DiffKind, ignoreWhitespace: Bool = false) -> [String] {
    let base: [String]
    switch kind {
    case .workingTree:
      base = ["diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3"]
    case .staged:
      base = ["diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--cached"]
    case .commit(let sha):
      // `git show` produces the same unified-diff stream. `--format=` suppresses the commit
      // header — the caller already has that data via `GitService.log`.
      base = ["show", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--format=", sha]
    }
    return ignoreWhitespace ? base + ["-w"] : base
  }

  static func status() -> [String] {
    ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
  }

  static func revParseShowToplevel() -> [String] {
    ["rev-parse", "--show-toplevel"]
  }
}
