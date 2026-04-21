import ComposableArchitecture
import Foundation

// MARK: - Public value types

/// JSON shape returned by `wt ls --json`. Field names match the upstream
/// `git-wt` output; `is_bare` maps to `isBare` via `CodingKeys`.
nonisolated struct GitWtEntry: Decodable, Equatable, Sendable {
  let branch: String
  let path: String
  let head: String
  let isBare: Bool

  enum CodingKeys: String, CodingKey {
    case branch, path, head
    case isBare = "is_bare"
  }
}

/// Input spec for `createWorktreeStream`. The caller pre-sanitizes `name`
/// to the on-disk directory name (via `GitWorktreeClient.sanitizeBranchName`
/// or an equivalent), which may differ from `branch` when the branch name
/// contains characters that aren't safe as a directory name.
nonisolated struct CreateWorktreeSpec: Equatable, Sendable {
  var repoRoot: URL
  var baseDirectory: URL
  var name: String
  var branch: String
  var baseRef: String
  var fetchOrigin: Bool
  var copyIgnored: Bool
  var copyUntracked: Bool
}

/// Stream events emitted while `wt sw` runs. Consumers render
/// `.progressLine` verbatim in the Create sheet's log area; `.finished`
/// signals completion and carries the newly-created worktree path.
nonisolated enum CreateWorktreeEvent: Equatable, Sendable {
  case progressLine(String)
  case finished(worktreePath: URL)
}

/// Typed errors surfaced by `GitWorktreeClient`. UI-visible cases
/// (`.uncommittedChanges`, `.branchExists`, `.invalidBranchName`, etc.)
/// drive tailored dialogs; `.commandFailed` is the catch-all that
/// round-trips the underlying git command + stderr.
nonisolated enum GitWorktreeError: Error, Equatable, Sendable {
  case executableMissing
  case branchExists(String)
  case invalidBranchName(String)
  case refNotFound(String)
  case fetchFailed(String)
  case uncommittedChanges(files: [String])
  case worktreeLocked(String)
  case commandFailed(command: String, stderr: String)
}

// MARK: - Client

/// Async-closures dependency covering the worktree-management spec's git
/// surface. Wraps the bundled `wt` script (for `ls --json`, streaming
/// create) plus a few complementary `/usr/bin/git` invocations (ref
/// queries, `worktree remove`, `worktree prune`, `fetch`). Closures run
/// off the main actor; callers `await` at call sites.
///
/// The live implementation is filled in by a later milestone; this type
/// scaffolds the shape so features and tests can link it now.
nonisolated struct GitWorktreeClient: Sendable {
  var lsWorktrees: @Sendable (_ repoRoot: URL) async throws -> [GitWtEntry]
  var localBranchNames: @Sendable (_ repoRoot: URL) async throws -> Set<String>
  var branchRefs: @Sendable (_ repoRoot: URL) async throws -> [String]
  var defaultRemoteBranchRef: @Sendable (_ repoRoot: URL) async throws -> String?
  var isValidBranchName: @Sendable (_ repoRoot: URL, _ name: String) async -> Bool

  var createWorktreeStream: @Sendable (_ spec: CreateWorktreeSpec)
    -> AsyncThrowingStream<CreateWorktreeEvent, Error>

  var removeWorktree: @Sendable (
    _ repoRoot: URL, _ path: URL, _ force: Bool
  ) async throws -> Void
  var pruneWorktrees: @Sendable (_ repoRoot: URL) async throws -> Int

  var fetchRemote: @Sendable (_ repoRoot: URL, _ remote: String) async throws -> Void
  var changedFiles: @Sendable (_ worktreeRoot: URL) async throws -> [String]
}

// MARK: - Pure helpers (visible for tests)

extension GitWorktreeClient {
  /// Derives a filesystem-safe directory name from a branch name. Replaces
  /// `/` with `-`, strips characters that break on macOS filesystems (`\0`,
  /// `:`), collapses consecutive `-` runs, and trims leading/trailing
  /// dashes. Intentionally conservative; a collision with an existing
  /// directory is a hard error at create time (W-Q5) rather than being
  /// silently suffixed.
  static func sanitizeBranchName(_ branch: String) -> String {
    var scalars: [Character] = []
    for ch in branch {
      switch ch {
      case "/":
        scalars.append("-")
      case "\0", ":", "\\":
        continue
      default:
        scalars.append(ch)
      }
    }
    let replaced = String(scalars)
    // Collapse repeated dashes.
    var collapsed = ""
    var lastWasDash = false
    for ch in replaced {
      if ch == "-" {
        if !lastWasDash { collapsed.append(ch) }
        lastWasDash = true
      } else {
        collapsed.append(ch)
        lastWasDash = false
      }
    }
    // Trim leading/trailing dashes.
    while collapsed.first == "-" { collapsed.removeFirst() }
    while collapsed.last == "-" { collapsed.removeLast() }
    return collapsed
  }

  /// Constructs the `wt` argv for a streaming `sw` (switch-and-create)
  /// invocation. Mirrors supacode's `createWorktreeArguments` — order
  /// matters for the helper's own parsing.
  static func makeCreateArguments(for spec: CreateWorktreeSpec) -> [String] {
    var arguments = ["--base-dir", spec.baseDirectory.path(percentEncoded: false), "sw"]
    if spec.copyIgnored { arguments.append("--copy-ignored") }
    if spec.copyUntracked { arguments.append("--copy-untracked") }
    if !spec.baseRef.isEmpty {
      arguments.append("--from")
      arguments.append(spec.baseRef)
    }
    if spec.copyIgnored || spec.copyUntracked {
      arguments.append("--verbose")
    }
    arguments.append(spec.name)
    return arguments
  }

  /// Heuristic-maps `git worktree remove` stderr onto the typed error
  /// cases. Unknown patterns fall through to `.commandFailed`. Callers
  /// that need `.uncommittedChanges(files:)` populate `files` from
  /// `git status --porcelain` separately.
  static func mapGitStderr(command: String, stderr: String) -> GitWorktreeError {
    let lower = stderr.lowercased()
    if let match = stderr.firstMatch(of: /A branch named '([^']+)' already exists/) {
      return .branchExists(String(match.1))
    }
    if let match = stderr.firstMatch(of: /'([^']+)' is not a valid branch name/) {
      return .invalidBranchName(String(match.1))
    }
    if lower.contains("unknown revision") || lower.contains("bad revision") {
      return .refNotFound(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains("is locked") {
      return .worktreeLocked(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains("contains modified or untracked files") {
      return .uncommittedChanges(files: [])
    }
    return .commandFailed(
      command: command,
      stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Parses `git status --porcelain` output into a list of file paths.
  /// Strips the two-character status prefix (XY) plus the following space.
  /// Index arithmetic is byte-safe: we drop a fixed three-byte prefix from
  /// the UTF-8 view rather than stepping `String.Index` to avoid any
  /// surprises with composed characters in file names.
  static func parsePorcelainPaths(_ output: String) -> [String] {
    var paths: [String] = []
    for rawLine in output.components(separatedBy: "\n") {
      guard rawLine.utf8.count >= 4 else { continue }
      let utf8 = rawLine.utf8
      let start = utf8.index(utf8.startIndex, offsetBy: 3)
      guard let trimmed = String(utf8[start...])?.trimmingCharacters(in: .whitespaces),
            !trimmed.isEmpty else { continue }
      paths.append(trimmed)
    }
    return paths
  }
}

// MARK: - DependencyKey

extension GitWorktreeClient: DependencyKey {
  /// Unusable placeholder — the real implementation lands in a follow-up
  /// commit. Attempting to invoke any closure throws
  /// `GitWorktreeError.executableMissing` so callers that accidentally
  /// depend on it before wiring fail loudly and clearly.
  static let liveValue: GitWorktreeClient = GitWorktreeClient(
    lsWorktrees: { _ in throw GitWorktreeError.executableMissing },
    localBranchNames: { _ in throw GitWorktreeError.executableMissing },
    branchRefs: { _ in throw GitWorktreeError.executableMissing },
    defaultRemoteBranchRef: { _ in throw GitWorktreeError.executableMissing },
    isValidBranchName: { _, _ in false },
    createWorktreeStream: { _ in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: GitWorktreeError.executableMissing)
      }
    },
    removeWorktree: { _, _, _ in throw GitWorktreeError.executableMissing },
    pruneWorktrees: { _ in throw GitWorktreeError.executableMissing },
    fetchRemote: { _, _ in throw GitWorktreeError.executableMissing },
    changedFiles: { _ in throw GitWorktreeError.executableMissing }
  )

  static let testValue: GitWorktreeClient = GitWorktreeClient(
    lsWorktrees: unimplemented("GitWorktreeClient.lsWorktrees", placeholder: []),
    localBranchNames: unimplemented("GitWorktreeClient.localBranchNames", placeholder: []),
    branchRefs: unimplemented("GitWorktreeClient.branchRefs", placeholder: []),
    defaultRemoteBranchRef: unimplemented("GitWorktreeClient.defaultRemoteBranchRef", placeholder: nil),
    isValidBranchName: unimplemented("GitWorktreeClient.isValidBranchName", placeholder: false),
    createWorktreeStream: { _ in
      AsyncThrowingStream { $0.finish() }
    },
    removeWorktree: unimplemented("GitWorktreeClient.removeWorktree"),
    pruneWorktrees: unimplemented("GitWorktreeClient.pruneWorktrees", placeholder: 0),
    fetchRemote: unimplemented("GitWorktreeClient.fetchRemote"),
    changedFiles: unimplemented("GitWorktreeClient.changedFiles", placeholder: [])
  )
}

extension DependencyValues {
  var gitWorktreeClient: GitWorktreeClient {
    get { self[GitWorktreeClient.self] }
    set { self[GitWorktreeClient.self] = newValue }
  }
}
