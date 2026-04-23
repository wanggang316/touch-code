# Design Doc: Read-Only Git Diff / History Viewer (C7)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-20

## Context and Scope

touch-code ships a small in-app surface for inspecting the Git state of the currently selected Worktree. [Product-spec C7](../product-spec.md) pins the intent: a *read-only* viewer for working-tree diff, staged diff, commit log, and per-commit diff. Anything beyond inspection — staging, committing, merging, editing — is deliberately delegated: terminal Panes already host `git`/`lazygit`; external editors (C8) already host diff/merge UIs. touch-code is not an IDE.

The viewer exists because the user switches Worktrees constantly and wants *quick* answers to "what changed here?" and "what did I commit yesterday?" without leaving the app. It is the smallest useful read surface compatible with a terminal-first tool.

Repository state at design time:

- C1 (Terminal engine) + C2 (Hierarchy) are approved in design-doc [0001](0001-terminal-and-hierarchy.md). The viewer consumes the Worktree selection that C2 publishes via `HierarchyManager`.
- `apps/mac/touch-code/Git/` exists as a near-empty folder containing a single `public enum Git {}` namespace. This design is the first substantive content that module will hold.
- The architecture invariants (see [architecture.md § Architectural Invariants](../architecture.md)) are taken as given: Runtime-free read path, `TouchCodeCore` leafness, TCA for feature flows, atomic-rename persistence, UUID identifiers.
- Reference projects confirm the minimalism: supacode ships only aggregate line counts (`git diff HEAD --shortstat`) and no diff viewer at all; supaterm has no git code. This is greenfield within touch-code — no prior in-app viewer to migrate.

This document is the source of truth for how C7 is structured. It does not specify C8 (editor integration, sibling doc), and does not replace the CLI design (C4) — C7 does not currently expose any IPC surface.

## Goals and Non-Goals

**Goals**

- Render, for the selected Worktree, four read-only views: **working-tree diff**, **staged diff**, **commit log** (most-recent first, paginated), and **per-commit diff** (when a commit row is selected).
- Show a file-level change list for each diff view; selecting a file scrolls the unified-diff hunks for that file into the reading pane.
- Meet the product-spec NFR: first 1 000-line diff renders in **< 200 ms** on an M1 after the `git` process returns.
- Work keyboard-first (`j`/`k` navigation, `Tab` to switch pane focus, `Enter` to open a file in the external editor via C8). Keep the surface usable without touching the mouse.
- Use the hybrid state pattern already chosen for this app (TCA for the feature; `@Observable` only where per-event volume matters — here it does not). Keep the viewer a pure consumer of the Worktree that C2 publishes.
- Keep all code in `touch-code/Git/` (in-app module) with pure-function parsers and data types that could later move to `TouchCodeCore` if an iOS or CLI consumer needs them.

**Non-Goals**

- **No writes.** No staging, unstaging, committing, amending, resetting, stashing, branching, merging, rebasing, cherry-picking, reverting, or reflog manipulation. None.
- **No editor.** The viewer shows diffs; "open this file to edit it" is a hand-off to C8.
- **No merge-conflict UI** — conflicts render as ordinary unified diff with `<<<<<<<` markers; resolution is external.
- **No syntax highlighting** in v1. Plaintext, monospace, selectable. Call out as Future Consideration.
- **No blame, file history, word-level diff, 3-way view, inline comments, graph log, or stash browser** in v1.
- **No IPC surface (`git.*` methods)** in v1. The viewer is an in-app UI; `tc` already has shell access to plain `git` inside any Pane. Leave the namespace reserved (see Seams).
- **No libgit2 / SwiftGit2 / other FFI.** Shell out to `git`.
- **No submodule recursion** — submodule pointers render as a single line ("subproject commit $SHA → $SHA"), which is `git`'s default.

## Design

### Overview

The viewer is a single TCA feature, `GitViewerFeature`, that lives in the app's in-app module and reads from a small, purely functional data layer that lives in `touch-code/Git/`. The data layer is a thin typed wrapper around `git` invocations via `Foundation.Process`; it does no I/O caching and holds no mutable state. Between the two sits `GitService` (protocol + live implementation), injected into the TCA feature via a `DependencyKey` — the standard shape for testable TCA features.

There are three load-bearing decisions, covered in [Alternatives Considered](#alternatives-considered):

1. **Shell out to `git`, not libgit2.** Lowest integration cost, zero FFI, exactly the pace the spec permits (user-driven, <200 ms for the biggest diff anyone is likely to read). We gain portability-of-thought ("whatever `git` at the terminal would show is what you see") and we lose nothing we actually need.
2. **TCA, not `@Observable`.** C7 is feature-flow state (which commit is selected, which pane is focused, which file is active). Volume is low — a few UI events per second. The architecture's own text names `GitViewer` as a TCA feature, and the reducer shape gives us deterministic snapshot tests.
3. **Worktree-scoped; rebuild on activation, no cross-Worktree cache.** The viewer's state is attached to the currently selected `WorktreeID`. Switching Worktrees invalidates and re-issues. v1 pays the per-switch cost honestly; caching is a named Future Consideration.

Why this is enough. The viewer's only hot operations are "paginate the log" and "render one commit's diff". Both are linear in user attention (the human reads one commit at a time), not in repo size. Latency matters only when the user selects a row — under 200 ms feels instant, and `git show <sha>` on a typical 1 000-line commit runs well under that before parsing. Parsing is O(lines) with a hand-rolled unified-diff parser, and SwiftUI renders hunks lazily via `LazyVStack`.

### System Context Diagram

```
        ┌──────────────────────────────────────────────────────────┐
        │  touch-code app window (macOS, per Space)               │
        │                                                          │
        │  ┌──────────────────┐    ┌────────────────────────────┐  │
        │  │  Sidebar: Hier.  │    │  GitViewerView (SwiftUI)   │  │
        │  │  (C2 TCA feat.)  │    │                            │  │
        │  │                  │    │  ┌──────────┬───────────┐  │  │
        │  │   [Worktree X]──────▶ │  │  Log /   │  Diff +   │  │  │
        │  │   selection      │    │  │  Changes │  Hunks    │  │  │
        │  └──────────────────┘    │  └──────────┴───────────┘  │  │
        │                          │  Scope: Working / Staged / │  │
        │                          │          Log  / Commit     │  │
        │                          └─────────────┬──────────────┘  │
        │                                        │ actions         │
        │                                        ▼                 │
        │                         ┌──────────────────────────┐     │
        │                         │  GitViewerFeature (TCA)  │     │
        │                         └──────────┬───────────────┘     │
        │                                    │ GitService (DI)     │
        │                                    ▼                     │
        │                         ┌──────────────────────────┐     │
        │                         │  touch-code/Git/         │     │
        │                         │   ├ GitService (proto)   │     │
        │                         │   ├ LiveGitService       │ ────┼─▶ Process: /usr/bin/env git ...
        │                         │   ├ GitOutputParser      │     │      (one child per request)
        │                         │   └ DiffParser           │     │
        │                         └──────────────────────────┘     │
        └──────────────────────────────────────────────────────────┘
                                                    ▲
                                                    │ (reads)
                                            HierarchyManager.selectedWorktree
                                            (C2; @Observable; no writes from C7)
```

External boundaries C7 touches:

- **`git` CLI** — the only external dependency. Invoked with fixed argument lists and no shell interpretation. Working directory is set to `Worktree.path`. Arguments are our own, never user input (the one exception — the commit SHA — is a `[0-9a-f]{7,40}` regex-validated token, see Security).
- **File system (read-only)** — `git` itself reads `.git/`; C7 does not open files directly. The viewer never writes.
- **C2 `HierarchyManager`** — read `selectedWorktree: Worktree?`. No write path.
- **C8 `EditorService`** — on `Enter`, call `editorService.openDirectory(worktree.path, preferred: nil)`. v1 always opens the Worktree directory, even when a file row is selected; file-level opens are not in the v1 `EditorService` protocol (see C8 non-goals). No other coupling.

### API Design

Two surfaces: (i) the TCA feature boundary (what the app shell and sidebar call into), and (ii) the `GitService` protocol the feature calls into. Both are internal to the `touch-code` app target.

#### GitViewerFeature (TCA reducer — sketch)

```swift
@Reducer
struct GitViewerFeature {
  struct State: Equatable {
    var worktreeID: WorktreeID?        // nil → "No Worktree selected" empty state
    var scope: Scope = .working        // .working | .staged | .log | .commit(SHA)
    var log: LogState = .idle          // paginated commit list
    var diff: DiffState = .idle        // current unified diff
    var focus: PaneFocus = .list       // .list | .hunks
    var selectedFilePath: String?      // within the current diff
  }
  enum Action {
    case worktreeSelected(WorktreeID?)
    case scopeChanged(Scope)
    case refreshRequested
    case logResponse(Result<LogPage, GitError>)
    case diffResponse(Result<UnifiedDiff, GitError>)
    case fileSelected(path: String)
    case commitSelected(sha: String)
    case openInEditorRequested                  // delegate to C8: opens Worktree dir (no file-level in v1)
    case keyboardNavigation(Direction)
  }
  @Dependency(\.gitService) var git
  @Dependency(\.editorService) var editor
  // body: wires actions to effects calling git.log / git.workingTreeDiff / ...
}
```

Scope enum:

```swift
enum Scope: Equatable {
  case working               // git diff
  case staged                // git diff --cached
  case log                   // commit list; selecting an entry moves to .commit
  case commit(sha: String)   // git show <sha>
}
```

The feature does **not** expose its own state or effects outside its module. External callers interact via one read-only boolean (`isEmptyState`) and one command (`.worktreeSelected`) through the root reducer binding.

#### GitService protocol

```swift
public protocol GitService: Sendable {
  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage
  func workingTreeDiff(at path: URL) async throws -> UnifiedDiff
  func stagedDiff(at path: URL) async throws -> UnifiedDiff
  func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff
  func status(at path: URL) async throws -> WorkingTreeStatus   // changed-file list + flags
}
```

The live implementation runs a `Process` per call. Three shapes are used:

| Method | Command | Notes |
|---|---|---|
| `log` | `git log --pretty=format:%H%x00%an%x00%ae%x00%aI%x00%s%x00%P%x00 --no-color -z --date=iso-strict -n <limit> [--skip <offset>]` | `%x00` null-byte delimiters; `-z` disables default newline separation; trivial to parse. Pagination via `--skip` / `-n`. |
| `workingTreeDiff` / `stagedDiff` / `commitDiff` | `git diff --no-color --no-ext-diff -M -C -U3 [--cached] [SHA^..SHA]` | `--no-ext-diff` blocks user-configured external diff tools (those could be editors that trap us); `-M -C` surface renames/copies (equivalent to `--find-renames --find-copies`); `-U3` standard context. |
| `status` | `git status --porcelain=v1 -z --untracked-files=all` | Used to populate the changed-file list for working-tree scope without parsing the full diff. |

All Process invocations:

- Set `cwd = worktree.path` (absolute, validated to exist).
- Null `stdin`; collect `stdout` + `stderr` in memory.
- Cap total output at **16 MiB**; when exceeded, emit `GitError.outputTooLarge` and show a "diff too large — open in terminal" placeholder with a pre-built `git` command to copy.
- Enforce a **10 s wall-clock timeout**; on exceed, terminate and emit `.timedOut`.
- Child inherits `PATH`, `HOME`, `LC_ALL=C.UTF-8`, nothing else — stripped of `GIT_*` env that could redirect operations.

#### Data models (unified diff + log)

```swift
public struct LogPage: Equatable, Sendable {
  public struct Cursor: Equatable, Sendable { let offset: Int; let limit: Int }
  public var cursor: Cursor
  public var commits: [Commit]
  public var hasMore: Bool
}

public struct Commit: Equatable, Sendable, Identifiable {
  public let id: String              // full SHA-1 or SHA-256 from git (no truncation)
  public let authorName: String
  public let authorEmail: String
  public let date: Date              // author-date, ISO-strict
  public let subject: String         // first line of message only
  public let parents: [String]       // full SHAs; [] = root, ≥2 = merge

  /// Display-only short hash. Always computed from `id`, never parsed from git output,
  /// so SHA-256 repositories and any future hash length Just Work.
  public var shortID: String { String(id.prefix(7)) }
}

public struct UnifiedDiff: Equatable, Sendable {
  public var scope: Scope
  public var files: [FileChange]
}

public struct FileChange: Equatable, Sendable, Identifiable {
  public enum Kind: Equatable, Sendable {
    case added, deleted, modified, renamed(from: String), copied(from: String), typeChanged
  }
  public var id: String              // post-image path (or pre-image if deleted)
  public var kind: Kind
  public var isBinary: Bool
  public var linesAdded: Int
  public var linesRemoved: Int
  public var hunks: [DiffHunk]
}

public struct DiffHunk: Equatable, Sendable {
  public var header: String          // raw `@@ -a,b +c,d @@` line incl. any section hint
  public var oldStart: Int; public var oldCount: Int
  public var newStart: Int; public var newCount: Int
  public var lines: [DiffLine]
}

public struct DiffLine: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case context, added, removed, noNewlineMarker }
  public var kind: Kind
  public var text: String
}
```

Rationale: the data types are small, `Equatable`, `Sendable`, contain only primitives. They cross the TCA boundary cleanly (TCA reducers want `Equatable` state). They live in `touch-code/Git/` for now and can be promoted to `TouchCodeCore` with zero code change if a CLI / iOS consumer appears.

### Data Storage

**None.** C7 has no persistent state of its own.

- `catalog.json` does not gain a `gitViewer` section. Scope/focus/selection are ephemeral.
- No caching to disk, no index.
- On app launch, the viewer begins in its `idle` state for whatever Worktree C2 reports as selected. First user interaction issues the first `git` child.

This is deliberate. Caching is the wrong thing to add before we have a measurement. Inspection latency is bounded by `git`'s own cost on a warm file-system cache, and on the machines in scope (developer laptops) that is already sub-100 ms for the operations we run.

### Component Boundaries

```
touch-code/Git (in-app module)
├── GitService.swift               ─ protocol + @Dependency wiring (lives here so feature + core share it)
├── LiveGitService.swift           ─ Process-based implementation
├── GitCommand.swift               ─ builder for git argv (no shell)
├── GitOutputParser.swift          ─ null-delimited log parser; status parser
├── DiffParser.swift               ─ unified-diff parser (pure; no I/O)
├── GitModels.swift                ─ Commit, FileChange, DiffHunk, DiffLine, UnifiedDiff, LogPage
├── GitError.swift                 ─ structured errors: .notARepo, .outputTooLarge, .timedOut, .gitMissing, .exec(code, stderr)
└── Git.swift                      ─ (existing) public enum Git {} namespace; re-exports selected types

touch-code/App (in-app module; TCA)
├── Features/GitViewer/
│   ├── GitViewerFeature.swift     ─ reducer + state + action
│   ├── GitViewerView.swift        ─ root SwiftUI view (3-pane layout)
│   ├── CommitLogView.swift        ─ left pane for .log scope
│   ├── FileChangeListView.swift   ─ left pane for .working/.staged/.commit scopes
│   ├── UnifiedDiffView.swift      ─ right pane renderer
│   └── GitViewerKeybindings.swift ─ j/k/g/G/Tab/Enter dispatch
└── Clients/GitServiceClient.swift ─ @DependencyKey for GitService (parallel to TerminalClient)
```

**Dependency rules** (on top of [architecture.md § Dependency Direction](../architecture.md)):

- `touch-code/Git` must not import `Runtime`, `Hooks`, `App`, `GhosttyKit`, `ComposableArchitecture`, or SwiftUI/AppKit. It is pure Swift over Foundation + `TouchCodeCore`.
- `touch-code/App/Features/GitViewer` may import `touch-code/Git` and `ComposableArchitecture`. It owns the reducer and the views.
- No code in `touch-code/Git` holds reference-type state. Everything returned is a value type.
- The editor-open action is an `openInEditorRequested` delegated via `EditorService` (C8). C7 must not invoke `open` / `Process` to launch an editor — that is C8's single responsibility.

**What each component is NOT responsible for:**

- `GitService`: not responsible for UI, not responsible for TCA, not responsible for the Worktree model. It receives a `URL` and returns a value.
- `GitViewerFeature`: not responsible for running `git`. Every side effect goes through `GitService`.
- `DiffParser`: not responsible for syntax awareness — it does not know the file's language. It returns hunks of plaintext lines with `added/removed/context` classification, and nothing else.
- `GitViewerView`: not responsible for persistence, not responsible for cross-Worktree state.

### Rendering

- Three-pane layout inside the viewer region. Left = scope-dependent list (commits or files). Center = file list when scope is `.log` + a commit is selected. Right = unified-diff hunks.
- Monospace font throughout (`SF Mono` / system monospaced), `Text` with selection enabled.
- Colour: added lines in a restrained green, removed in a restrained red, context neutral. Line numbers (old/new) in a dimmed column left of content. Colours source from the app's theme tokens (light + dark).
- `LazyVStack` over `hunks.flatMap(\.lines)`. Each line is one `HStack { oldNo; newNo; marker; Text(line.text) }`. At ~18pt line height × monospace, 1 000 lines is ~18 000 pt of virtual height — well within SwiftUI's lazy rendering sweet spot.
- File-change list renders status glyphs (`A`, `M`, `D`, `R→`, `C→`, `T`) and the per-file `+N −M` counts.
- Empty states: "No Worktree selected", "Working tree is clean", "No staged changes", "No commits yet", "Not a git repository" (for Projects with `gitRoot == nil` — the viewer shows this and offers nothing else).
- "Large diff" cutoff: when a single `UnifiedDiff` exceeds **50 000 lines** total, the right pane renders a placeholder with per-file summary rows and a "Copy command" button that puts a shell-ready command on the pasteboard. The command always begins with `cd <absolute-worktree-path> && ` so it pastes successfully into any terminal regardless of the target shell's CWD. Scope-dependent suffix:
  - `.working`  → `cd /abs/path && git diff --no-color`
  - `.staged`   → `cd /abs/path && git diff --no-color --cached`
  - `.commit`   → `cd /abs/path && git show --no-color <sha>`
  - `.log`      → not applicable (log is paginated, never hits the cutoff)

  Paths containing whitespace or shell metacharacters are single-quoted (`'…'`) in the `cd` argument; a path containing a literal `'` is escaped via `'\''` (standard POSIX sh escaping). No parsing past the cutoff.

### Keyboard navigation

- `j` / `k` — move selection within the focused pane (list or file or hunk).
- `g` / `G` — first / last row in focused list.
- `Tab` — cycle focus: list → files (if log+commit) → hunks → list.
- `Enter` — hand off to C8 `editorService.openDirectory(worktree.path, preferred: nil)` (opens the *Worktree directory*, not the selected file — v1 has no file-level hand-off). When a commit row is selected, `Enter` first moves into the commit-file list; pressing `Enter` again there triggers the directory hand-off.
- `r` — refresh current scope (re-issue the `git` child).
- `1` / `2` / `3` — switch scope to working / staged / log.
- `.` — toggle whitespace-ignored diff (pass `-w` to `git diff` — cheap variant because it adds no new parser paths).
- `/` — focus a file-name filter input in the file list (client-side; filters the decoded `files` array, no new git invocation).

### Performance

- **< 200 ms render for a 1 000-line diff** (product-spec NFR).
  - Budget: up to ~80 ms for `git` wall-clock (measured in supacode's `GitClient` shortstat path on a warm cache and generalises), up to ~40 ms for parsing, up to ~60 ms for first layout, ~20 ms slack.
  - Measurements will be captured via a simple `ContinuousClock.Instant` trace on `GitService` calls; recorded to `os.signpost` under category `com.touch-code.git` for Instruments correlation.
- **Concurrent invocations.** The feature holds a single in-flight request per scope. Switching scope or selecting a new commit cancels the prior `Process` via `process.terminate()` and drops its output. This prevents a slow repo from queuing stale results.
- **Memory.** Raw `git` output is capped at 16 MiB and 50 000 lines per parsed diff. Parsed model size relative to raw output is not profiled in the design — if it becomes a concern, we measure on real fixtures before tightening the cap.
- **UI responsiveness.** Parsing happens off the main actor (`Task.detached`); the reducer receives the finished `UnifiedDiff` on `@MainActor`. SwiftUI lazy stacks render visible rows only.

### Error handling

- `GitError.notARepo` — Worktree path is not a git repository (no `.git`). Show "Not a git repository" empty state with no retry.
- `GitError.gitMissing` — `git` binary not found in PATH. Show "Install Xcode Command Line Tools" text with no retry (an extreme edge case on macOS, but worth a clear message).
- `GitError.outputTooLarge` — hit the 16 MiB cap. Show placeholder + shell command.
- `GitError.timedOut` — `git` exceeded 10 s. Show "Taking too long — retry or open in terminal" with a retry button.
- `GitError.exec(code, stderr)` — non-zero exit. Show the first line of stderr as the error banner and offer "Copy full message".
- Transient failures (non-zero exit while `index.lock` exists, for example) auto-retry once after 300 ms, matching supacode's approach.

### Testing strategy

- **`DiffParser` (pure)** — exhaustive table-driven tests. Inputs are fixture files under `apps/mac/TouchCodeCoreTests/Fixtures/git/`; outputs are `UnifiedDiff` values. Cover: added/removed/modified, rename, copy, binary, mode-change, empty-file, missing-newline-at-eof, merge-commit triple-stream, CRLF mixed.
- **`GitOutputParser` (pure)** — null-delimited log parser tests (incl. UTF-8 names, empty subject, merge with ≥2 parents, root commit with 0 parents).
- **`LiveGitService` (integration)** — an XCTest target that creates a temporary git repo via `git init`, makes scripted commits, and asserts the service returns the expected values. Gated behind `TC_RUN_GIT_INTEGRATION_TESTS=1` so CI can opt in; it runs fast (< 1 s per test) on any machine with `git` installed.
- **`GitViewerFeature` (reducer)** — TCA TestStore with a mocked `GitService` that replays fixtures. Cover: scope transitions, pagination, cancellation on scope change, error paths, editor-open action delegation.
- **`GitViewerView` (snapshot)** — a small snapshot suite for the three render states (log, working diff, commit diff) and each empty state. Uses deterministic fixtures; checked into git.

The test pyramid is flat — the data path is pure, so ~80 % of the value comes from parser tests; the reducer tests cover composition; the integration + snapshot layers guard against regression.

### Seams left for later capabilities

- **`git.*` IPC namespace reserved.** Not implemented in v1. If a user asks for `tc git log` or `tc git diff`, the CLI can later forward to the same `GitService`. The `GitService` protocol is already IPC-payload-shaped.
- **Syntax highlighting.** `DiffLine` carries `text: String`; a later extension can carry attributed spans without changing the structure. A plan to add TreeSitter-based highlighting is deferred; until then, monospace plaintext.
- **Caching.** If and when inspection latency becomes measurable (e.g. on network-mounted repos), add an LRU of `(worktreeID, scope) → UnifiedDiff` keyed on the current `HEAD` SHA. The interface does not change.
- **`blame`, `file history`, `graph log`.** Each is an additional `GitService` method + a new TCA view. Non-trivial but compositional — no v1 code blocks them.
- **Commit-range diff.** Scope can grow `.range(from:to:)` without a new concept.

## Alternatives Considered

### A1. libgit2 / SwiftGit2

Link libgit2 (or SwiftGit2 as a Swift façade) and read objects directly.

- **Pros:** no Process startup overhead; finer-grained control; no PATH dependency.
- **Cons:** adds a native dependency (static or XCFramework), adds build-system work, adds surface for bugs in libgit2 version skew vs. user's `git` config (esp. around `core.hooksPath`, `include.path`, `credential.helper`). We gain capabilities we do not need (C7 is read-only; we never write; we never authenticate). supacode uses shell invocation for its only git interaction and it works. Per-invocation cost on macOS is ~10–30 ms; that is well inside our 200 ms budget.
- **Verdict:** rejected. Return to only if profiling shows Process overhead dominating inspection latency.

### A2. Custom wire format (`git log --format=…` with JSON shape via `jq`/custom)

Write a shell pipeline that emits pre-JSONified commit records to avoid parsing.

- **Pros:** simpler Swift-side parser.
- **Cons:** adds a `jq` dependency; `git log --format` does not natively emit JSON; escaping arbitrary subjects/messages into JSON without a proper encoder is how SQL-injection-style bugs get born. Null-byte delimiters (`%x00`) + `split(separator: 0)` is simpler and bulletproof.
- **Verdict:** rejected.

### A3. One long-running `git cat-file --batch` process

Keep a persistent `git cat-file --batch` child per Worktree; stream SHA requests to it for commit body and tree reads.

- **Pros:** amortises process startup across commits.
- **Cons:** manual protocol framing, manual lifecycle per Worktree, background process management, no use of `git`'s own caching for diff text (which is the 80% of volume). Startup amortisation buys nothing for scopes dominated by diff text.
- **Verdict:** rejected. Revisit only if log pagination becomes the bottleneck.

### A4. Render diffs in the terminal (Pane) rather than in SwiftUI

Feed `git diff` into a side-Pane and rely on libghostty to render.

- **Pros:** leverage existing renderer; free colour support.
- **Cons:** loses selection, filter, file list, file-level navigation; conflates viewer state with terminal state; breaks keyboard-navigation semantics (Pane inputs would bind to `git`, not to `j/k` nav). The whole point of having a viewer is that `git` in a terminal already exists and users want a structured surface.
- **Verdict:** rejected — reimplements why the viewer is a separate surface at all.

### A5. `@Observable` feature instead of TCA

Structure `GitViewerFeature` as a reference-type `@Observable` class like `HierarchyManager`.

- **Pros:** one fewer framework; lower boilerplate.
- **Cons:** low-volume feature state (clicks, scope changes, selection) is exactly the shape TCA was designed for — deterministic reducer, effect cancellation, `TestStore`. We already buy TCA for Settings, CommandPalette, Updates. Consistency beats micro-optimisation here; architecture.md explicitly names `GitViewer` as a TCA consumer.
- **Verdict:** rejected.

### A6. Cache unified diffs on disk (`~/.cache/touch-code/git/<worktree>/...`)

Keep parsed diffs under `~/.cache/` keyed by `(worktreeID, scope, HEAD SHA)`.

- **Pros:** switching back to a previously viewed commit is instant.
- **Cons:** introduces cache-invalidation surface (working-tree scope is never valid for cache — it changes on every save; commit scope is valid but must invalidate on rebase/amend which rewrites SHAs). The v1 inspection cost is already imperceptible on local repos; caching is optimisation ahead of measurement.
- **Verdict:** rejected for v1; listed as a Seam.

### A7. Show the user `git log --graph --all`

Render a graph log with branch topology.

- **Pros:** richer information.
- **Cons:** graph rendering is its own UI project; character-cell rendering via SwiftUI requires explicit grid layout; users who want this launch `tig` or `lazygit` in a Pane, which is strictly better at it. Drops the minimalism the whole viewer is premised on.
- **Verdict:** rejected — not in goal set.

## Cross-Cutting Concerns

### Security

- **No shell interpolation.** `Process.arguments` is always an array literal; the only user-sourced string ever passed is the commit SHA for `.commit` scope, and it is validated against `^[0-9a-fA-F]{7,64}$` before it reaches `GitCommand`. File paths from `git` output are consumed as decoded strings, never re-executed.
- **Environment stripping.** Child inherits `PATH`, `HOME`, `LC_ALL=C.UTF-8`. Explicitly unset: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_EDITOR`, `GIT_PAGER`, `GIT_EXTERNAL_DIFF`, `GIT_EXEC_PATH`, `GIT_CONFIG`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_GLOBAL`, `GIT_SSH`, `GIT_ASKPASS` — these could redirect the invocation or spawn interactive prompts.
- **Symlink traversal.** Worktree paths are taken from the hierarchy (user-chosen at Project/Worktree creation time); C7 does not canonicalise-and-escape. The attack surface is whatever the user already granted `git` access to.
- **Binary output.** Diffs for binary files are reported as "Binary files differ" by git; we display that as-is and do not try to decode the file.

### Observability

- `os.Logger` category `com.touch-code.git`. Every `GitService` call logs start/finish at `.debug`, exit-code + stderr first line at `.info` on non-zero exit. Log pagination and diff parsing emit `os.signpost` regions for Instruments.
- Hot-path rendering (per-line) logs nothing.

### Accessibility

- Full VoiceOver labels on each diff line (`"added line: …"`, `"removed line: …"`, `"context line: …"`) and on file rows (`"added file path/to/x"`).
- Keyboard navigation covers every interactive surface; no mouse-only interaction exists.
- Colour is not the sole signal for added/removed — glyphs (`+`, `−`) are always present.

### Theming & font

- Uses the app's existing monospaced font tokens (same as Pane rendering). Users who change the Pane font from Settings see the same change in the viewer.
- Diff colours live under a new `Theme.git.{added,removed,context,renamed}` namespace; defaults track the current light/dark palette, overridable later.

### Migration path

- v1 ships without persistent state; any future schema addition (e.g. "pinned commits per Worktree") goes into a new `gitViewer` section of `catalog.json` with the top-level `version` bump per the architecture invariant.

## Risks

- **R1 — `git` version drift.** `--pretty=format:%aI` requires `git ≥ 2.2`; `-z --porcelain=v1` is stable but `--porcelain=v2` has better rename info. Mitigation: stick to v1 porcelain and `%aI`, which cover macOS system `git` ≥ macOS 13. Document the floor.
- **R2 — Diff parser false negatives on exotic output.** `git` has obscure output for merge commits (combined diffs), symlink changes, typechanges, and submodule diffs. Mitigation: every known case is a parser fixture; an unknown shape falls back to rendering the raw text in the right pane under a "Unrecognised diff format — showing raw output" banner rather than crashing.
- **R3 — Long-running `git` calls on network volumes or large repos.** 10 s timeout is a guess; may be wrong for some real repos. Mitigation: keep the timeout tunable via `Settings.gitTimeoutMs`; log the 95th-percentile wall-clock during dogfooding and adjust.
- **R4 — `index.lock` races.** When the user is mid-commit in a Pane, `git status` and `git diff --cached` can error with "another git process seems to be running". Mitigation: single automatic retry after 300 ms (inherited from supacode's pattern); on second failure surface the error verbatim.
- **R5 — SwiftUI large-text rendering regressions.** Apple's lazy stacks have historically regressed on very long monospaced content across OS versions. Mitigation: 50 000-line cutoff; measure on every OS version we support; if a regression lands, fall back to `NSTextView` inside an `NSViewRepresentable` specifically for hunk rendering.
- **R6 — Feature creep toward write ops.** Users (including the author) will ask for "just a quick stage button". Mitigation: the non-goals section is load-bearing; any write-ops proposal must be its own design doc and must justify the expansion of scope on evidence from dogfooding, not anticipation.
- **R7 — C8 coupling.** The `Enter` key depends on `EditorService` being resolvable. If C8 is not yet present, the action is a no-op with a status-bar notice. Mitigation: the delegate protocol has a default no-op implementation so C7 can land before C8.

## Resolved Items (locked at approval)

At approval the following defaults are locked. Revisit via amendment only.

1. **Invocation mechanism.** Shell out to `git` via `Process` with fixed argv. No libgit2 in v1.
2. **Pagination.** `log` pages 100 commits at a time via `-n 100 --skip <offset>`. Scroll-to-bottom triggers the next page.
3. **Diff context size.** `-U3` (git default). User-configurable later; not a v1 setting.
4. **Output cap.** 16 MiB per `git` child; 50 000 lines per parsed diff.
5. **Timeout.** 10 s wall-clock per `git` child.
6. **Rename/copy detection.** Always on (`-M -C`); no user toggle in v1.
7. **Whitespace-ignore toggle.** `.` key flips `-w` on/off for the current scope. Not persisted.
8. **Editor hand-off on `Enter`.** Delegates to `EditorService.openDirectory(worktree.path, preferred: nil)` (C8). Opens the Worktree directory, not the selected file (no file-level hand-off in v1 — see C8 non-goals).
9. **Non-git Projects.** Viewer renders the "Not a git repository" empty state for Projects with `gitRoot == nil`; no other UI.
