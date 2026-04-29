import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA reducer behind the Diff inspector + drawer.
///
/// Owns two separable workflows:
///   1. **Changed-files list** — driven by `worktreeSelected(...)`, fetched
///      via `GitServiceClient.diffNumstat`. Surfaces in the inspector.
///   2. **Per-file diff** — driven by `fileRowTapped(path:)`, fetched
///      lazily on first tap, cached in `diffsByPath`. Surfaces in the
///      drawer.
///
/// Cancellation:
///   - `CancelID.changedFiles` — cancels any prior changed-files load when
///     a new `worktreeSelected` arrives.
///   - `CancelID.diff(path)` — per-path slot; re-tapping the same row
///     while a load is in flight cancels the prior load.
///
/// Cap thresholds (`maxFileBytes`, `maxFileLines`) live as static
/// constants so tests can reference them without going through the
/// reducer instance.
@Reducer
struct DiffFeature {
  /// 500 KB. Above this, the drawer renders a "too large" placeholder.
  nonisolated static let maxFileBytes: Int = 500_000
  /// 5 000 lines. Above this on either side, same placeholder.
  nonisolated static let maxFileLines: Int = 5_000

  @ObservableState
  struct State: Equatable {
    /// Cached identifiers for the currently-active Worktree. Set by
    /// `worktreeSelected(...)`. `nil` means no Worktree is targeted —
    /// inspector renders an empty state.
    var worktreeID: WorktreeID?
    var projectID: ProjectID?
    var worktreePath: String?

    var changedFiles: ChangedFilesState = .idle
    /// Path of the file currently displayed in the drawer; `nil` = drawer
    /// hidden. Re-tapping the row whose path matches is a no-op.
    var presentedFilePath: String?
    /// Per-path diff cache. Survives drawer close — only cleared when
    /// `worktreeSelected(...)` switches to a different Worktree.
    var diffsByPath: [String: DiffEntryState] = [:]
    /// Mirrors `@AppStorage("diffStyle")`; the picker view writes both.
    var style: DiffStyle = .unified
  }

  enum ChangedFilesState: Equatable {
    case idle
    case loading
    case loaded([ChangedFile])
    case error(GitError)
  }

  enum DiffEntryState: Equatable {
    case loading
    case loaded(LoadedDiffDocument)
    case error(GitError)
    case tooLarge(reason: TooLargeReason, copyCommand: String)
  }

  /// Reference wrapper for a loaded `DiffDocument`. Equality is identity-
  /// based (`===`) so `DiffEntryState.loaded` equality stays O(1) regardless
  /// of file size. SwiftUI re-evaluations rebuild State around the same
  /// instance, so a wrapper compares equal to itself by reference; a fresh
  /// load produces a new instance which compares unequal — the only two
  /// transitions we care about for view diffing.
  final class LoadedDiffDocument: Equatable, @unchecked Sendable {
    let document: DiffDocument
    init(_ document: DiffDocument) { self.document = document }
    static func == (lhs: LoadedDiffDocument, rhs: LoadedDiffDocument) -> Bool {
      lhs === rhs
    }
  }

  enum TooLargeReason: Equatable {
    case byteCount(Int)
    case lineCount(Int)
    case binary
  }

  enum Action: Equatable {
    case worktreeSelected(projectID: ProjectID?, worktreeID: WorktreeID?, path: String?)
    case refreshRequested
    case changedFilesSucceeded([ChangedFile])
    case changedFilesFailed(GitError)
    case fileRowTapped(path: String)
    case drawerCloseRequested
    case diffSucceededFor(path: String, document: DiffDocument)
    case diffFailedFor(path: String, error: GitError)
    case diffTooLargeFor(path: String, reason: TooLargeReason, copyCommand: String)
    case styleChanged(DiffStyle)
  }

  /// `nonisolated` because TCA's `.cancellable(id:)` requires `Hashable & Sendable`.
  /// Flat enum without per-path payload — a single `.diff` slot ensures any
  /// in-flight per-file load is cancelled both when a new row is tapped and
  /// when the active Worktree changes, so a stale load can't write into the
  /// fresh Worktree's `diffsByPath`.
  nonisolated enum CancelID: Hashable, Sendable {
    case changedFiles
    case diff
  }

  @Dependency(GitServiceClient.self) private var gitService

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case let .worktreeSelected(projectID, worktreeID, path):
        // Switching Worktree drops the prior cache; presentedFilePath
        // also resets so a stale drawer doesn't linger across switches.
        state.projectID = projectID
        state.worktreeID = worktreeID
        state.worktreePath = path
        state.presentedFilePath = nil
        state.diffsByPath = [:]
        guard worktreeID != nil, let path, !path.isEmpty else {
          state.changedFiles = .idle
          // Cancel any inflight loads from the previous worktree.
          return .merge(
            .cancel(id: CancelID.changedFiles),
            .cancel(id: CancelID.diff)
          )
        }
        state.changedFiles = .loading
        return .merge(
          .cancel(id: CancelID.diff),
          loadChangedFiles(at: path)
        )

      case .refreshRequested:
        // Re-issue the changed-files load using the cached path. The
        // per-file cache is preserved — refresh is meant for "I just
        // edited files in the worktree, recompute the list," not "I
        // switched Worktrees." (Decision Log D16.)
        guard let path = state.worktreePath, !path.isEmpty else { return .none }
        state.changedFiles = .loading
        return loadChangedFiles(at: path)

      case .changedFilesSucceeded(let files):
        state.changedFiles = .loaded(files)
        return .none

      case .changedFilesFailed(let error):
        state.changedFiles = .error(error)
        return .none

      case .fileRowTapped(let path):
        // Re-tapping the open row is a no-op (the chevron / × button
        // own the close path; row body is open-only).
        if state.presentedFilePath == path { return .none }
        state.presentedFilePath = path
        // Cache hit on `.loaded` / `.error` / `.tooLarge`: don't refetch.
        if let existing = state.diffsByPath[path], existing != .loading {
          return .none
        }
        state.diffsByPath[path] = .loading
        guard let worktreePath = state.worktreePath, !worktreePath.isEmpty else {
          return .send(.diffFailedFor(path: path, error: .invalidInput("missing worktree path")))
        }
        return loadDiff(forPath: path, worktreePath: worktreePath)

      case .drawerCloseRequested:
        // Cache survives — re-tapping a row that was previously opened
        // re-uses the loaded DiffDocument without re-fetch.
        state.presentedFilePath = nil
        return .none

      case let .diffSucceededFor(path, document):
        state.diffsByPath[path] = .loaded(LoadedDiffDocument(document))
        return .none

      case let .diffFailedFor(path, error):
        state.diffsByPath[path] = .error(error)
        return .none

      case let .diffTooLargeFor(path, reason, copyCommand):
        state.diffsByPath[path] = .tooLarge(reason: reason, copyCommand: copyCommand)
        return .none

      case .styleChanged(let style):
        state.style = style
        return .none
      }
    }
  }

  // MARK: - Effect builders

  private func loadChangedFiles(at worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let files = try await gitService.diffNumstat(worktreePath)
        await send(.changedFilesSucceeded(files))
      } catch let error as GitError {
        await send(.changedFilesFailed(error))
      } catch {
        await send(.changedFilesFailed(.unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.changedFiles, cancelInFlight: true)
  }

  private func loadDiff(forPath path: String, worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        // `git show HEAD:<path>` for the baseline; nil means the path is
        // newly added (no HEAD blob exists). Filesystem read for the
        // working-tree side; failure to read counts the file as deleted
        // (empty new contents).
        let oldContents = (try? await gitService.showFileAtHEAD(path, worktreePath)) ?? ""
        let newContentsURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(path)
        let newContents = (try? String(contentsOf: newContentsURL, encoding: .utf8)) ?? ""

        // Cap checks. Byte count first (cheaper than splitting lines on
        // a half-megabyte string). Binary-detection lives upstream in
        // `diffNumstat`; if the per-file load reaches here it's textual.
        let oldBytes = oldContents.utf8.count
        let newBytes = newContents.utf8.count
        if oldBytes > Self.maxFileBytes || newBytes > Self.maxFileBytes {
          let reason = TooLargeReason.byteCount(max(oldBytes, newBytes))
          let cmd = Self.copyCommand(worktreePath: worktreePath, path: path)
          await send(.diffTooLargeFor(path: path, reason: reason, copyCommand: cmd))
          return
        }
        let oldLines = oldContents.split(separator: "\n", omittingEmptySubsequences: false).count
        let newLines = newContents.split(separator: "\n", omittingEmptySubsequences: false).count
        if oldLines > Self.maxFileLines || newLines > Self.maxFileLines {
          let reason = TooLargeReason.lineCount(max(oldLines, newLines))
          let cmd = Self.copyCommand(worktreePath: worktreePath, path: path)
          await send(.diffTooLargeFor(path: path, reason: reason, copyCommand: cmd))
          return
        }

        // `DiffFile` / `DiffDocument` are SwiftUI-adjacent types whose
        // initializers inherit the App target's MainActor default isolation —
        // hop onto the main actor to construct them, then send the result.
        let document = await MainActor.run { () -> DiffDocument in
          let file = DiffFile(
            oldPath: oldContents.isEmpty ? nil : path,
            newPath: newContents.isEmpty ? nil : path,
            oldContents: oldContents,
            newContents: newContents
          )
          return DiffDocument(files: [file], title: path)
        }
        await send(.diffSucceededFor(path: path, document: document))
      } catch let error as GitError {
        await send(.diffFailedFor(path: path, error: error))
      } catch {
        await send(.diffFailedFor(path: path, error: .unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.diff, cancelInFlight: true)
  }

  // MARK: - Helpers

  /// POSIX shell-quote a single argument by wrapping in single quotes and
  /// escaping any embedded single quote as `'\''`. Matches the helper the
  /// retired `LargeDiffCommand.swift` used (verified via git history at
  /// commit `e66f48b`).
  nonisolated static func copyCommand(worktreePath: String, path: String) -> String {
    "cd \(posixQuote(worktreePath)) && git diff \(posixQuote(path))"
  }

  nonisolated private static func posixQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

// MARK: - Inspector row model

/// One row in the Diff inspector. Built by `GitServiceClient.diffNumstat`
/// from `git diff --numstat -z` + `git diff --name-status -z`. `addedLines`
/// / `removedLines` are -1 sentinels for binary files (see `isBinary`).
///
/// `public` because the `GitService` protocol (also `public`) takes this
/// as a return type — Swift won't let a public method's result be
/// internal even when both live in the same module.
public nonisolated struct ChangedFile: Equatable, Identifiable, Sendable {
  public var id: String { newPath ?? oldPath ?? "" }
  public let oldPath: String?
  public let newPath: String?
  public let status: ChangeStatus
  public let addedLines: Int
  public let removedLines: Int
  public let isBinary: Bool

  public init(
    oldPath: String?,
    newPath: String?,
    status: ChangeStatus,
    addedLines: Int,
    removedLines: Int,
    isBinary: Bool
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.status = status
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.isBinary = isBinary
  }
}

public nonisolated enum ChangeStatus: String, Equatable, Sendable {
  case modified
  case added
  case deleted
  case renamed
}
